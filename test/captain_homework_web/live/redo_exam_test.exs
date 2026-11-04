defmodule CaptainHomeworkWeb.RedoExamTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Exams, QuestionDefinitions, Repo, Study, Uploads}

  setup do
    old = Application.fetch_env!(:captain_homework, :uploads_dir)
    dir = Path.join(System.tmp_dir!(), "redo-exam-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)
    Application.put_env(:captain_homework, :uploads_dir, dir)

    on_exit(fn ->
      Application.put_env(:captain_homework, :uploads_dir, old)
      File.rm_rf!(dir)
    end)

    %{lesson: lesson(profile()), dir: dir}
  end

  defp completed(lesson, format, questions \\ [question()]) do
    exam(lesson, questions)
    |> Ecto.Changeset.change(
      format: format,
      status: "completed",
      card_index: length(questions),
      submitted_at: DateTime.utc_now(),
      grading_started_at: DateTime.utc_now(),
      score: 20.0,
      appreciation: "Très bien",
      answers: %{"q1" => "Une limite"},
      corrections: %{"q1" => %{"points" => 4, "fraction" => 1.0, "feedback" => "Correct"}}
    )
    |> Repo.update!()
  end

  test "redo opens a fresh classic or flashcard control and preserves the original", %{
    conn: conn,
    lesson: lesson
  } do
    for format <- ["classic", "flashcard"] do
      original = completed(lesson, format)
      {:ok, view, _} = live(conn, "/alice/controles/#{original.id}")
      assert has_element?(view, "#exam-footer #delete-exam + span + #redo-exam")
      view |> element("#redo-exam") |> render_click()
      {path, _} = assert_redirect(view)
      copy = Study.get_exam!(lesson.profile_id, List.last(String.split(path, "/")))

      assert copy.id != original.id
      assert copy.questions == original.questions
      assert copy.format == original.format
      assert copy.instructions == original.instructions
      assert copy.question_types == original.question_types
      assert QuestionDefinitions.for_exam(copy) == QuestionDefinitions.for_exam(original)
      assert copy.status == "in_progress"
      assert copy.answers == %{}
      assert copy.corrections == %{}
      assert copy.card_index == 0
      assert is_nil(copy.score)
      assert is_nil(copy.appreciation)
      assert is_nil(copy.submitted_at)
      assert is_nil(copy.grading_started_at)
      assert Repo.get!(Study.Exam, original.id) == original

      {:ok, fresh, _} = live(conn, path)

      assert has_element?(
               fresh,
               if(format == "classic", do: "#exam-answers", else: "#flashcard-q1")
             )

      refute has_element?(fresh, "#redo-exam")
    end
  end

  test "illustrations remain available after deleting the original", %{lesson: lesson} do
    File.write!(Uploads.path("original.png"), "image data")

    asset = %{
      "id" => Ecto.UUID.generate(),
      "storage_key" => "original.png",
      "content_type" => "image/png"
    }

    original = completed(lesson, "classic", [Map.put(question(), "images", [asset])])
    assert {:ok, copy} = Exams.redo(lesson.profile_id, original.id)
    [image] = hd(copy.questions)["images"]
    assert image["id"] != asset["id"]
    assert image["storage_key"] != asset["storage_key"]
    assert {:ok, _} = Study.delete_exam(lesson.profile_id, original.id)
    assert File.read!(Uploads.path(image["storage_key"])) == "image data"
    assert {:ok, _} = Study.delete_exam(lesson.profile_id, copy.id)
    refute File.exists?(Uploads.path(image["storage_key"]))
  end

  test "only completed controls belonging to the profile can be duplicated", %{lesson: lesson} do
    original = exam(lesson)
    assert {:error, :not_completed} = Exams.redo(lesson.profile_id, original.id)
    other_profile = profile("Marius")
    assert_raise Ecto.NoResultsError, fn -> Exams.redo(other_profile.id, original.id) end
    assert length(Study.get_lesson!(lesson.profile_id, lesson.id).exams) == 1
  end

  test "a missing illustration leaves no partial copy or orphaned file", %{
    lesson: lesson,
    dir: dir
  } do
    File.write!(Uploads.path("original.png"), "image data")

    questions =
      for {id, key} <- [{"q1", "original.png"}, {"q2", "missing.png"}] do
        Map.put(question(id), "images", [
          %{"id" => id, "storage_key" => key, "content_type" => "image/png"}
        ])
      end

    original = completed(lesson, "classic", questions)
    assert {:error, :illustration_unavailable} = Exams.redo(lesson.profile_id, original.id)
    assert File.ls!(dir) == ["original.png"]
    assert length(Study.get_lesson!(lesson.profile_id, lesson.id).exams) == 1
  end
end

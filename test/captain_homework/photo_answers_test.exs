defmodule CaptainHomework.PhotoAnswersTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Exams, Study, Repo, Uploads, QuestionDefinitions}
  alias CaptainHomework.Exams.PhotoAnswers

  setup do
    path = Path.join(System.tmp_dir!(), "drawing-#{Ecto.UUID.generate()}.png")
    File.write!(path, <<137, 80, 78, 71, 13, 10, 26, 10, 0>>)
    on_exit(fn -> File.rm(path) end)
    %{path: path, exam: exam(lesson(profile()), [question("q1", "photo"), question("q2")])}
  end

  test "persist, replace and remove photos without accepting forged answer metadata", %{
    path: path,
    exam: e
  } do
    {:ok, saved} = PhotoAnswers.put(profile().id, e.id, "q1", path, "dessin.png")
    asset = saved.answers["q1"]
    assert File.exists?(Uploads.path(asset["storage_key"]))
    assert Study.get_exam!(profile().id, e.id).answers["q1"] == asset

    {:ok, saved} =
      Study.save_answers(profile().id, e.id, %{
        "q1" => %{"storage_key" => "forged.png"},
        "q2" => "Explication"
      })

    assert saved.answers["q1"] == asset
    {:ok, replaced} = PhotoAnswers.put(profile().id, e.id, "q1", path, "nouveau.png")
    refute File.exists?(Uploads.path(asset["storage_key"]))
    assert replaced.answers["q2"] == "Explication"
    {:ok, removed} = PhotoAnswers.remove(profile().id, e.id, "q1")
    assert removed.answers["q1"] == ""
    refute File.exists?(Uploads.path(replaced.answers["q1"]["storage_key"]))
  end

  test "reject wrong owner, text questions, invalid files and submitted copies", %{
    path: path,
    exam: e
  } do
    assert_raise Ecto.NoResultsError, fn ->
      PhotoAnswers.put(profile("Marius").id, e.id, "q1", path, "drawing.png")
    end

    assert {:error, _} = PhotoAnswers.put(profile().id, e.id, "q2", path, "drawing.png")
    File.write!(path, "not an image")
    assert {:error, _} = PhotoAnswers.put(profile().id, e.id, "q1", path, "drawing.png")
    Repo.update!(Ecto.Changeset.change(e, status: "grading"))
    assert {:error, _} = PhotoAnswers.remove(profile().id, e.id, "q1")
    assert {:error, _} = PhotoAnswers.put(profile().id, e.id, "q1", path, "drawing.png")
  end

  test "deleting an unfinished control removes stored answers", %{path: path, exam: e} do
    {:ok, saved} = PhotoAnswers.put(profile().id, e.id, "q1", path, "drawing.png")
    {:ok, _} = Study.delete_exam(profile().id, e.id)
    refute File.exists?(Uploads.path(saved.answers["q1"]["storage_key"]))
  end

  test "deleting a completed control also removes its stored photo answer", %{path: path, exam: e} do
    {:ok, saved} = PhotoAnswers.put(profile().id, e.id, "q1", path, "drawing.png")

    saved
    |> Ecto.Changeset.change(status: "completed", submitted_at: DateTime.utc_now())
    |> Repo.update!()

    assert {:ok, _} = Study.delete_exam(profile().id, e.id)
    refute Repo.get(Study.Exam, e.id)
    refute File.exists?(Uploads.path(saved.answers["q1"]["storage_key"]))
  end

  test "the photo renderer is eligible for classic generation, never flashcards", %{exam: e} do
    old = Application.fetch_env!(:captain_homework, :ai_provider)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.PhotoAI)
    on_exit(fn -> Application.put_env(:captain_homework, :ai_provider, old) end)
    lesson = Study.get_lesson!(profile().id, e.lesson_id)
    page(lesson)

    {:ok, type} =
      QuestionDefinitions.save(%Study.QuestionDefinition{}, %{
        name: "Dessin",
        subjects: ["svt"],
        response_kind: "photo",
        modes: ["classic"],
        instruction_kind: "dynamic",
        content_kind: "text",
        content_presence: "none",
        work_duration: "long"
      })

    assert QuestionDefinitions.generation_supported?(type)

    assert {:ok, generated} =
             Exams.generate(profile().id, lesson.id, 1, "", question_types: [type.id])

    assert generated.status == "in_progress"
    assert hd(generated.questions)["type"] == "photo"

    assert {:error, _} =
             Exams.generate(profile().id, lesson.id, 1, "",
               question_types: [type.id],
               format: "flashcard"
             )

    assert CaptainHomework.Exams.Constraints.compatible?("photo", "developed", "knowledge", [
             %{kind: "lesson"}
           ])
  end

  test "grading sends the image, keeps it in the result and ignores bogus language errors", %{
    exam: e,
    path: path
  } do
    keys = [:openai_api_key, :openai_request_options, :ai_provider]
    old = Map.new(keys, &{&1, Application.fetch_env(:captain_homework, &1)})
    Application.put_env(:captain_homework, :openai_api_key, "test-only-key")
    Application.put_env(:captain_homework, :openai_request_options, plug: {Req.Test, __MODULE__})
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.AI.OpenAI)

    on_exit(fn ->
      Enum.each(old, fn
        {k, {:ok, v}} -> Application.put_env(:captain_homework, k, v)
        {k, :error} -> Application.delete_env(:captain_homework, k)
      end)
    end)

    {:ok, saved} = PhotoAnswers.put(profile().id, e.id, "q1", path, "drawing.png")
    on_exit(fn -> PhotoAnswers.delete_files(saved) end)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      content = Jason.decode!(body)["input"] |> hd() |> Map.fetch!("content")

      assert Enum.any?(
               content,
               &(&1["type"] == "input_image" and
                   String.starts_with?(&1["image_url"], "data:image/png;base64,"))
             )

      assert Enum.any?(
               content,
               &(&1["type"] == "input_text" and &1["text"] =~ "RÉPONSE DE L’ÉLÈVE — question q1")
             )

      refute hd(content)["text"] =~ saved.answers["q1"]["storage_key"]

      result = %{
        appreciation: "Bonne construction.",
        grades: [
          %{id: "q1", fraction: 1, feedback: "Figure correcte.", language_errors: []},
          %{id: "q2", fraction: 0, feedback: "Sans réponse.", language_errors: []}
        ]
      }

      Req.Test.json(conn, %{
        status: "completed",
        output: [%{content: [%{type: "output_text", text: Jason.encode!(result)}]}]
      })
    end)

    assert {:ok, _} = Exams.submit(profile().id, e.id, %{}, sync: true)
    corrected = Study.get_exam!(profile().id, e.id)
    assert corrected.status == "completed"
    assert corrected.answers["q1"] == saved.answers["q1"]
    assert corrected.corrections["q1"]["points"] == 4
  end
end

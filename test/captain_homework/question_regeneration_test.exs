defmodule CaptainHomework.QuestionRegenerationTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Accounts, Exams, Repo, Study}
  alias CaptainHomework.Exams.QuestionRegeneration, as: Regeneration

  setup do
    old = Application.fetch_env!(:captain_homework, :ai_provider)
    on_exit(fn -> Application.put_env(:captain_homework, :ai_provider, old) end)
    p = profile()
    l = lesson(p)
    page(l)

    other =
      question("other")
      |> Map.put("prompt", "Combien de pattes a une araignée ?")
      |> Map.put("answer", "Huit")

    e = exam(l, [other, question("target"), Map.put(other, "id", "last")])

    e =
      e
      |> Ecto.Changeset.change(
        answers: %{"other" => "huit", "target" => "ancienne réponse", "last" => "huit"}
      )
      |> Repo.update!()

    %{profile: p, exam: e, types: question_type_ids(["long"]), parent: Accounts.get("parent-1")}
  end

  test "replacement is atomic, preserves order and other answers, and stays out of exam lists",
       c do
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.TestAI)

    assert {:ok, result} =
             Regeneration.start(
               c.parent,
               c.profile.id,
               c.exam.id,
               "target",
               c.types,
               "Une nouvelle question",
               sync: true
             )

    assert result.regeneration["status"] == "ready"
    [first, replacement, last] = result.questions
    assert first == hd(c.exam.questions)
    assert last == List.last(c.exam.questions)
    assert replacement["id"] != "target"
    assert replacement["prompt"] == "Question nouvelle 1"
    assert result.answers == %{"other" => "huit", "last" => "huit"}
    assert length(Study.get_lesson!(c.profile.id, c.exam.lesson_id).exams) == 1
    assert Study.exam_counts(c.profile.id)["svt"] == 1
    job = Regeneration.job(result)
    assert job.status == "in_progress"
    assert job.generation_history != []
    assert_raise Ecto.NoResultsError, fn -> Study.get_exam!(c.profile.id, job.id) end
  end

  test "an uncorrected flashcard can be replaced without resetting progress", c do
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.FlashcardAI)

    c.exam
    |> Ecto.Changeset.change(
      format: "flashcard",
      card_index: 1,
      corrections: %{"other" => %{"fraction" => 1}}
    )
    |> Repo.update!()

    assert {:ok, result} =
             Regeneration.start(
               c.parent,
               c.profile.id,
               c.exam.id,
               "target",
               question_type_ids(["definition"]),
               "",
               sync: true
             )

    assert result.regeneration["status"] == "ready"
    assert result.card_index == 1
    assert result.corrections == %{"other" => %{"fraction" => 1}}
    refute Regeneration.allowed?(c.parent, result, "other")
  end

  test "failure preserves the original question and answer", c do
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.FailingAI)

    assert {:ok, result} =
             Regeneration.start(c.parent, c.profile.id, c.exam.id, "target", c.types, "",
               sync: true
             )

    assert result.regeneration["status"] == "failed"
    assert result.questions == c.exam.questions
    assert result.answers == c.exam.answers
    assert result.status == "in_progress"
  end

  test "failure and cancellation leave another replacement active", c do
    jobs =
      for id <- ["target", "other"] do
        Repo.insert!(%Study.Exam{
          lesson_id: c.exam.lesson_id,
          regeneration_source_id: c.exam.id,
          instructions: "",
          regeneration: %{"question_id" => id},
          status: "generating"
        })
      end

    [failed, running] = jobs

    states =
      Map.new(jobs, fn job ->
        id = job.regeneration["question_id"]
        {id, %{"question_id" => id, "job_id" => job.id, "status" => "generating"}}
      end)

    c.exam
    |> Ecto.Changeset.change(regeneration: %{"questions" => states, "status" => "generating"})
    |> Repo.update!()

    Regeneration.finished(%{failed | status: "generation_partial"})
    result = Study.get_exam!(c.profile.id, c.exam.id)
    assert Regeneration.state(result, "target")["status"] == "failed"
    assert Regeneration.state(result, "other")["status"] == "generating"
    assert result.questions == c.exam.questions
    assert result.answers == c.exam.answers
    assert {:error, _} = Exams.submit(c.profile.id, c.exam.id, %{}, sync: true)
    assert :ok = Regeneration.cancel(c.parent, c.profile.id, c.exam.id, failed.id)
    result = Study.get_exam!(c.profile.id, c.exam.id)
    refute Regeneration.pending?(result, "target")
    assert Regeneration.pending?(result, "other")
    assert Regeneration.running?(result)
    assert Regeneration.state(result, "other")["job_id"] == running.id
    assert result.answers == c.exam.answers
    assert {:error, _} = Exams.submit(c.profile.id, c.exam.id, %{}, sync: true)
  end

  test "forged requests by a child or family and requests after submission are denied", c do
    for role <- ~w(child-1 family) do
      assert {:error, _} =
               Regeneration.start(
                 Accounts.get(role),
                 c.profile.id,
                 c.exam.id,
                 "target",
                 c.types,
                 "",
                 sync: true
               )
    end

    c.exam |> Ecto.Changeset.change(status: "completed") |> Repo.update!()

    assert {:error, _} =
             Regeneration.start(c.parent, c.profile.id, c.exam.id, "target", c.types, "",
               sync: true
             )

    assert Repo.aggregate(Study.Exam, :count) == 1
  end

  test "in-flight replacement prevents submission and duplicate starts but saves other answers",
       c do
    state = %{"status" => "generating", "question_id" => "target"}
    c.exam |> Ecto.Changeset.change(regeneration: state) |> Repo.update!()

    assert {:error, _} =
             Regeneration.start(c.parent, c.profile.id, c.exam.id, "target", c.types, "",
               sync: true
             )

    assert {:error, _} = Exams.submit(c.profile.id, c.exam.id, %{}, sync: true)

    assert {:ok, saved} =
             Study.save_answers(c.profile.id, c.exam.id, %{
               "other" => "huit pattes",
               "last" => "huit"
             })

    assert saved.answers["target"] == "ancienne réponse"
    assert saved.answers["other"] == "huit pattes"
  end
end

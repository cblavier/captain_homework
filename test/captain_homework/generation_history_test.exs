defmodule CaptainHomework.GenerationHistoryTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.{AI, DetailedGenerationAI, Exams, Repo, Study}
  alias CaptainHomework.Exams.GenerationHistory

  setup do
    previous = AI.provider()
    Application.put_env(:captain_homework, :ai_provider, DetailedGenerationAI)
    on_exit(fn -> Application.put_env(:captain_homework, :ai_provider, previous) end)

    start_supervised!(%{
      id: DetailedGenerationAI,
      start: {Agent, :start_link, [fn -> %{calls: []} end, [name: DetailedGenerationAI]]}
    })

    lesson = lesson(profile())
    page(lesson)
    %{lesson: lesson}
  end

  defp configure(values), do: Agent.update(DetailedGenerationAI, &Map.merge(&1, values))
  defp calls, do: Agent.get(DetailedGenerationAI, & &1.calls)

  defp rejection,
    do:
      {:reject,
       %{
         "q2" => %{
           "kind" => "content",
           "reason" => "Le document ne contient que deux éléments.",
           "issue_codes" => ["content_inconsistent"]
         }
       }}

  defp statuses(entry), do: Enum.map(entry["events"], & &1["status"])

  test "flashcards keep one stable history entry per card", %{lesson: lesson} do
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.FlashcardAI)

    assert {:ok, complete} =
             Exams.generate(lesson.profile_id, lesson.id, 3, "",
               format: "flashcard",
               question_types: question_type_ids(["definition"])
             )

    assert complete.status == "in_progress"
    assert length(complete.generation_history) == 3
    assert Enum.all?(complete.generation_history, &(&1["status"] == "ready"))

    assert Enum.map(complete.questions, & &1["generation_id"]) ==
             Enum.map(complete.generation_history, & &1["id"])
  end

  test "successful repair keeps the rejection and actual versions without hidden answers", %{
    lesson: lesson
  } do
    configure(%{
      audits: [rejection(), :ok],
      content_repairs: [{:change_prompt, "Relève les deux éléments du document."}]
    })

    assert {:ok, generated} = Exams.generate(lesson.profile_id, lesson.id, 2, "")
    complete = Repo.get!(Study.Exam, generated.id)
    assert complete.status == "in_progress"
    assert [unchanged, repaired] = complete.generation_history
    assert unchanged["status"] == "ready"
    assert length(unchanged["versions"]) == 1
    refute GenerationHistory.corrected?(unchanged)
    assert repaired["status"] == "ready"
    assert GenerationHistory.corrected?(repaired)
    assert "rejected" in statuses(repaired)
    assert "repairing" in statuses(repaired)

    assert Enum.any?(
             repaired["events"],
             &(&1["reason"] == "Le document ne contient que deux éléments.")
           )

    assert [initial, latest] = repaired["versions"]
    assert initial["content"]["prompt"] == "Question 2"
    assert latest["content"]["prompt"] == "Relève les deux éléments du document."
    assert latest["changed"] == ["prompt"]
    refute Map.has_key?(latest["content"], "answer")
    refute Map.has_key?(latest["content"], "audio_script")
    refute Jason.encode!(repaired) =~ "Réponse 2"
    assert complete.generation_plan["review_diagnostics"] == %{}
    times = Enum.map(repaired["events"], & &1["elapsed_ms"])
    assert times == Enum.sort(times)
  end

  test "stagnation retains each failed attempt and resuming adds no fictional attempts", %{
    lesson: lesson
  } do
    configure(%{audits: [rejection(), rejection(), rejection()]})
    assert {:ok, partial} = Exams.generate(lesson.profile_id, lesson.id, 2, "")
    assert [ready, blocked] = partial.generation_history
    assert ready["status"] == "ready"
    assert blocked["status"] == "blocked"
    assert Enum.count(statuses(blocked), &(&1 == "rejected")) == 3
    assert Enum.count(statuses(blocked), &(&1 == "repairing")) == 2
    assert blocked["reason"] == "Le document ne contient que deux éléments."
    before = calls()
    assert {:ok, resumed} = Exams.resume_generation(lesson.profile_id, partial.id)
    assert calls() == before
    assert resumed.generation_history == partial.generation_history
  end

  test "an interrupted audit keeps the paid revision and resumes its question history", %{
    lesson: lesson
  } do
    configure(%{
      audits: [rejection(), {:error, "Vérification interrompue"}, :ok],
      content_repairs: [{:change_prompt, "Consigne déjà corrigée"}]
    })

    assert {:ok, partial} = Exams.generate(lesson.profile_id, lesson.id, 2, "")
    assert [ready, interrupted] = partial.generation_history
    assert ready["status"] == "ready"
    assert interrupted["status"] == "interrupted"
    assert length(interrupted["versions"]) == 2
    assert interrupted["reason"] == "Vérification interrompue"
    assert {:ok, complete} = Exams.resume_generation(lesson.profile_id, partial.id)
    assert [^ready, repaired] = complete.generation_history
    assert repaired["status"] == "ready"
    assert repaired["versions"] == interrupted["versions"]
    assert Enum.take(repaired["events"], length(interrupted["events"])) == interrupted["events"]
    assert Enum.count(calls(), &match?({:content_repair, _}, &1)) == 1
  end

  test "duplicate legacy drafts are attributed to their slot while valid questions stay ready", %{
    lesson: lesson
  } do
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.SequenceAI)
    first = question("first")
    duplicate = question("duplicate")
    replacement = question("replacement") |> Map.put("prompt", "Explique le rôle du noyau.")

    start_supervised!(%{
      id: CaptainHomework.SequenceAI,
      start:
        {Agent, :start_link,
         [
           fn -> %{calls: [], responses: [{:ok, [first, duplicate]}, {:ok, [replacement]}]} end,
           [name: CaptainHomework.SequenceAI]
         ]}
    })

    assert {:ok, complete} = Exams.generate(lesson.profile_id, lesson.id, 2, "")
    assert [ready, repaired] = complete.generation_history
    assert ready["status"] == "ready"
    assert length(ready["versions"]) == 1
    assert GenerationHistory.corrected?(repaired)
    assert Enum.any?(repaired["events"], &(&1["reason"] =~ "répète un énoncé"))

    assert Enum.map(complete.questions, & &1["generation_id"]) ==
             Enum.map(complete.generation_history, & &1["id"])
  end
end

defmodule CaptainHomework.DetailedGenerationTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.{AI, DetailedGenerationAI, Exams, Repo, Study}

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

  defp diagnostic(kind),
    do: %{
      "kind" => kind,
      "reason" => "Défaut #{kind} à corriger",
      "issue_codes" => [if(kind == "crop", do: "document_focused", else: "content")]
    }

  test "only rejected questions are repaired and accepted documentary questions keep their review and ID",
       %{
         lesson: lesson
       } do
    configure(%{audits: [{:reject, %{"q2" => diagnostic("content")}}, :ok]})
    assert {:ok, complete} = Exams.generate(lesson.profile_id, lesson.id, 2, "")
    assert complete.status == "in_progress"

    assert [{:plan, 2}, {:audit, first, _}, {:content_repair, ["q2"]}, {:audit, second, context}] =
             calls()

    assert Enum.map(first, & &1["plan_id"]) == ["q1", "q2"]
    assert Enum.map(second, & &1["plan_id"]) == ["q2"]
    assert [retained] = context.retained_questions
    assert retained["plan_id"] == "q1"
    assert Enum.find(complete.questions, &(&1["plan_id"] == "q1"))["id"] == retained["id"]
    assert complete.generation_plan["review_diagnostics"] == %{}
  end

  test "identical defects stop after two fruitless repairs and resume makes no more calls", %{
    lesson: lesson
  } do
    rejected = {:reject, %{"q2" => diagnostic("content")}}
    configure(%{audits: [rejected, rejected, rejected]})
    assert {:ok, partial} = Exams.generate(lesson.profile_id, lesson.id, 2, "")
    assert partial.status == "generation_partial"
    assert length(partial.questions) == 1
    assert partial.generation_plan["repair_progress"]["stagnant"] == 2
    assert partial.error =~ "n’améliorent plus"
    assert length(Enum.filter(calls(), &match?({:content_repair, _}, &1))) == 2
    before = calls()
    assert {:ok, resumed} = Exams.resume_generation(lesson.profile_id, partial.id)
    assert resumed.status == "generation_partial"
    assert calls() == before
    assert resumed.questions == partial.questions

    assert Repo.get!(Study.Exam, resumed.id).generation_plan["repair_progress"] ==
             partial.generation_plan["repair_progress"]
  end

  test "a paid content repair survives a failed audit and is not requested again", %{
    lesson: lesson
  } do
    configure(%{
      audits: [{:reject, %{"q2" => diagnostic("content")}}, {:error, "Audit interrompu"}, :ok],
      content_repairs: [{:change_prompt, "Question corrigée et déjà payée"}]
    })

    assert {:ok, partial} = Exams.generate(lesson.profile_id, lesson.id, 2, "")
    assert partial.status == "generation_partial"
    assert [draft] = partial.generation_plan["pending_drafts"]
    assert draft["prompt"] == "Question corrigée et déjà payée"
    assert {:ok, complete} = Exams.resume_generation(lesson.profile_id, partial.id)
    assert complete.status == "in_progress"
    assert Enum.find(complete.questions, &(&1["plan_id"] == "q2"))["prompt"] == draft["prompt"]
    assert length(Enum.filter(calls(), &match?({:content_repair, _}, &1))) == 1
  end

  test "older plans establish structured diagnostics before requesting a repair", %{
    lesson: lesson
  } do
    rejected = {:reject, %{"q2" => diagnostic("content")}}
    configure(%{audits: [rejected], content_repairs: [{:error, "Interruption"}]})
    {:ok, partial} = Exams.generate(lesson.profile_id, lesson.id, 2, "")
    plan = Map.drop(partial.generation_plan, ~w(review_diagnostics audit_cache repair_progress))
    Repo.update!(Ecto.Changeset.change(partial, generation_plan: plan))
    configure(%{calls: [], audits: [rejected, :ok], content_repairs: [:ok]})

    assert {:ok, complete} = Exams.resume_generation(lesson.profile_id, partial.id)
    assert complete.status == "in_progress"
    assert [{:audit, _, _}, {:content_repair, ["q2"]}, {:audit, _, _}] = calls()
  end

  test "a stale stalled review resumes with an audit, even after that audit is interrupted", %{
    lesson: lesson
  } do
    rejected = {:reject, %{"q2" => diagnostic("content")}}
    configure(%{audits: [rejected, rejected, rejected]})
    assert {:ok, partial} = Exams.generate(lesson.profile_id, lesson.id, 2, "")
    assert partial.generation_plan["repair_progress"]["stagnant"] == 2

    old_plan = Map.put(partial.generation_plan, "review_revision", 1)
    Repo.update!(Ecto.Changeset.change(partial, generation_plan: old_plan))
    configure(%{calls: [], audits: [{:error, "Audit interrompu"}, :ok]})

    assert {:ok, interrupted} = Exams.resume_generation(lesson.profile_id, partial.id)
    assert interrupted.status == "generation_partial"
    assert interrupted.questions == partial.questions
    assert interrupted.generation_plan["audit_pending"]
    assert interrupted.generation_plan["review_revision"] == Exams.AuditCache.revision()
    assert interrupted.generation_plan["review_diagnostics"] == %{}
    refute Map.has_key?(interrupted.generation_plan, "repair_progress")

    assert {:ok, complete} = Exams.resume_generation(lesson.profile_id, partial.id)
    assert complete.status == "in_progress"
    assert length(complete.questions) == 2
    assert [{:audit, first, _}, {:audit, second, _}] = calls()
    assert Enum.map(first, & &1["plan_id"]) == Enum.map(second, & &1["plan_id"])
    assert complete.generation_plan["review_diagnostics"] == %{}
  end

  test "a new review policy keeps paid pending drafts ahead of older plan content", %{
    lesson: lesson
  } do
    configure(%{
      audits: [{:reject, %{"q2" => diagnostic("content")}}, {:error, "Audit interrompu"}],
      content_repairs: [{:change_prompt, "Question corrigée et déjà payée"}]
    })

    assert {:ok, partial} = Exams.generate(lesson.profile_id, lesson.id, 3, "")
    assert [paid] = partial.generation_plan["pending_drafts"]

    old_plan =
      partial.generation_plan
      |> Map.put("review_revision", 1)
      |> Map.update!("questions", fn questions ->
        Enum.map(questions, fn question ->
          if question["id"] == paid["plan_id"],
            do: Map.put(question, "prompt", "Ancien brouillon"),
            else: question
        end)
      end)

    Repo.update!(Ecto.Changeset.change(partial, generation_plan: old_plan))
    configure(%{calls: [], audits: [:ok]})

    assert {:ok, complete} = Exams.resume_generation(lesson.profile_id, partial.id)
    assert complete.status == "in_progress"
    assert [{:audit, audited, _}] = calls()
    assert Enum.find(audited, &(&1["plan_id"] == "q2"))["prompt"] == paid["prompt"]
    assert Enum.find(complete.questions, &(&1["plan_id"] == "q2"))["prompt"] == paid["prompt"]
  end
end

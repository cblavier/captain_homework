defmodule CaptainHomework.GenerationCheckpointTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.{AI, Exams, Repo, PlannedGenerationAI}

  setup do
    previous = AI.provider()
    Application.put_env(:captain_homework, :ai_provider, PlannedGenerationAI)
    on_exit(fn -> Application.put_env(:captain_homework, :ai_provider, previous) end)

    start_supervised!(%{
      id: PlannedGenerationAI,
      start:
        {Agent, :start_link,
         [
           fn ->
             %{
               plans: [],
               repairs: 0,
               audits: [{:error, :invalid_effort_review}, :ok],
               audit_calls: 0
             }
           end,
           [name: PlannedGenerationAI]
         ]}
    })

    l = lesson(profile())
    pg = page(l)
    %{lesson: l, page: pg}
  end

  test "paid drafts survive an audit failure and resume only the audit", %{lesson: l} do
    assert {:ok, partial} = Exams.generate(l.profile_id, l.id, 2, "")
    assert partial.status == "generation_partial"
    assert partial.questions == []
    assert partial.generation_plan["audit_pending"]
    assert length(partial.generation_plan["pending_drafts"]) == 2
    assert {:ok, complete} = Exams.resume_generation(l.profile_id, partial.id)
    assert complete.status == "in_progress"
    assert length(complete.questions) == 2
    refute complete.generation_plan["audit_pending"]
    refute Map.has_key?(complete.generation_plan, "pending_drafts")
    assert %{plans: [_], repairs: 0, audit_calls: 2} = Agent.get(PlannedGenerationAI, & &1)
  end

  test "a rejected paid plan is checkpointed before repair and reused after transport failure", %{
    lesson: l
  } do
    Agent.update(PlannedGenerationAI, fn state ->
      Map.merge(state, %{
        plan_results: [{:reject, "Répartition à corriger"}],
        plan_repair_results: [{:error, "Indisponible"}, :ok],
        audits: [:ok],
        on_plan_repair: fn ->
          persisted = Repo.one!(CaptainHomework.Study.Exam)
          assert persisted.generation_plan["rejected_plan"]["questions"] != []
          assert persisted.generation_plan["rejection_reason"] == "Répartition à corriger"
          assert persisted.questions == []
        end
      })
    end)

    assert {:ok, partial} = Exams.generate(l.profile_id, l.id, 2, "")
    assert partial.status == "generation_partial"
    assert partial.questions == []
    assert partial.generation_plan["rejected_plan"]
    refute partial.generation_plan["audit_pending"]
    assert {:ok, complete} = Exams.resume_generation(l.profile_id, partial.id)
    assert complete.status == "in_progress"
    refute complete.generation_plan["rejected_plan"]

    assert %{plans: [_], plan_repairs: [first, second], audit_calls: 1} =
             Agent.get(PlannedGenerationAI, & &1)

    assert first == second
  end

  test "a rejected plan is discarded when its course source changes", %{lesson: l, page: pg} do
    Agent.update(PlannedGenerationAI, fn state ->
      Map.merge(state, %{
        plan_results: [{:reject, "Répartition à corriger"}, :ok],
        plan_repair_results: [{:error, "Indisponible"}],
        audits: [:ok]
      })
    end)

    assert {:ok, partial} = Exams.generate(l.profile_id, l.id, 2, "")
    Repo.update!(Ecto.Changeset.change(pg, text: "Le cours a changé"))
    assert {:ok, complete} = Exams.resume_generation(l.profile_id, partial.id)
    assert complete.status == "in_progress"

    assert %{plans: [_, _], plan_repairs: [_], audit_calls: 1} =
             Agent.get(PlannedGenerationAI, & &1)
  end

  test "a rejected plan cannot publish retained questions even when the target is reached", %{
    lesson: l
  } do
    old = exam(l, [question("old")])

    Repo.update!(
      Ecto.Changeset.change(old,
        status: "completed",
        submitted_at: DateTime.utc_now(),
        corrections: %{"old" => %{"fraction" => 0}}
      )
    )

    Agent.update(PlannedGenerationAI, fn state ->
      Map.merge(state, %{
        plan_results: [{:reject, "Plan incomplet"}],
        plan_repair_results: [{:reject, "Encore incomplet"}]
      })
    end)

    assert {:ok, partial} = Exams.generate(l.profile_id, l.id, 1, "")
    assert partial.status == "generation_partial"
    assert length(partial.questions) == 1
    assert partial.generation_plan["rejection_reason"] == "Encore incomplet"
    assert %{audit_calls: 0} = Agent.get(PlannedGenerationAI, & &1)
  end

  test "a resumed repair receives internal diagnostics after the public message was simplified",
       %{
         lesson: l
       } do
    diagnostic = "Question q1 : effort constaté developed. Réduis le barème à une seule idée."

    Agent.update(PlannedGenerationAI, fn state ->
      Map.merge(state, %{
        audits: [{:ok, [], [diagnostic]}, :ok],
        repair_results: [{:error, "Transport interrompu"}]
      })
    end)

    assert {:ok, partial} = Exams.generate(l.profile_id, l.id, 2, "")
    assert partial.status == "generation_partial"
    assert partial.generation_plan["repair_feedback"] =~ diagnostic
    refute diagnostic in partial.generation_errors
    assert {:ok, complete} = Exams.resume_generation(l.profile_id, partial.id)
    assert complete.status == "in_progress"
    instructions = Agent.get(PlannedGenerationAI, & &1.repair_instructions)
    assert length(instructions) == 2
    assert List.last(instructions) =~ diagnostic
  end

  test "a full set of retained questions is not published before the pending audit succeeds", %{
    lesson: l
  } do
    assert {:ok, partial} = Exams.generate(l.profile_id, l.id, 2, "")

    retained =
      Enum.map(
        partial.generation_plan["pending_drafts"],
        &CaptainHomework.Exams.Generation.identify/1
      )

    Repo.update!(Ecto.Changeset.change(partial, questions: retained))
    Agent.update(PlannedGenerationAI, &%{&1 | audits: [{:error, :invalid_effort_review}, :ok]})
    assert {:ok, still_partial} = Exams.resume_generation(l.profile_id, partial.id)
    assert still_partial.status == "generation_partial"
    assert still_partial.generation_plan["audit_pending"]
    assert {:ok, complete} = Exams.resume_generation(l.profile_id, partial.id)
    assert complete.status == "in_progress"
    assert %{plans: [_], repairs: 0, audit_calls: 3} = Agent.get(PlannedGenerationAI, & &1)
  end

  test "changed course source rebuilds the plan before resuming", %{lesson: l, page: pg} do
    assert {:ok, partial} = Exams.generate(l.profile_id, l.id, 2, "")
    Repo.update!(Ecto.Changeset.change(pg, text: "Contenu de cours corrigé"))
    assert {:ok, complete} = Exams.resume_generation(l.profile_id, partial.id)
    assert complete.status == "in_progress"
    assert %{plans: [_, _], repairs: 0} = Agent.get(PlannedGenerationAI, & &1)

    refute partial.generation_plan["source_fingerprint"] ==
             complete.generation_plan["source_fingerprint"]
  end

  test "reused questions have stable plan IDs and count toward the complete plan", %{lesson: l} do
    Agent.update(PlannedGenerationAI, &%{&1 | audits: [:ok]})

    questions =
      for n <- 1..2,
          do:
            question("old#{n}")
            |> Map.merge(%{
              "prompt" => "Ancienne question #{n}",
              "response_effort" => "direct",
              "image_ids" => []
            })

    old = exam(l, questions)

    Repo.update!(
      Ecto.Changeset.change(old,
        status: "completed",
        submitted_at: DateTime.utc_now(),
        corrections: Map.new(questions, &{&1["id"], %{"fraction" => 0}})
      )
    )

    assert {:ok, complete} = Exams.generate(l.profile_id, l.id, 4, "")
    assert complete.status == "in_progress"
    assert %{plans: [%{count: 4, kept: kept}], repairs: 0} = Agent.get(PlannedGenerationAI, & &1)
    assert length(kept) == 2
    ids = Enum.map(kept, & &1["plan_id"])
    assert Enum.all?(ids, &is_binary/1)
    assert length(Enum.uniq(ids)) == 2
    assert length(complete.questions) == 4
  end
end

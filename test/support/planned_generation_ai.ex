defmodule CaptainHomework.PlannedGenerationAI do
  @behaviour CaptainHomework.AI
  alias CaptainHomework.Exams.Plan
  def transcribe(_, _), do: {:error, "unused"}
  def grade(_), do: {:error, "unused"}
  def generate(_, _, _, _, _, _), do: {:error, "unexpected legacy generation"}

  def plan_control(lesson, pages, examples, count, _, kept, _) do
    Agent.update(
      __MODULE__,
      &Map.update!(&1, :plans, fn plans -> plans ++ [%{count: count, kept: kept}] end)
    )

    plan = build_plan(lesson, pages, examples, count, kept)
    plan_result(:plan_results, plan)
  end

  def repair_control_plan(lesson, pages, examples, count, _, kept, _, rejected) do
    callback =
      Agent.get_and_update(__MODULE__, fn state ->
        {Map.get(state, :on_plan_repair),
         Map.update(state, :plan_repairs, [rejected], &(&1 ++ [rejected]))}
      end)

    if callback, do: callback.()
    plan_result(:plan_repair_results, build_plan(lesson, pages, examples, count, kept))
  end

  defp plan_result(key, plan) do
    result =
      Agent.get_and_update(__MODULE__, fn state ->
        case Map.get(state, key, []) do
          [] -> {:ok, state}
          [result | rest] -> {result, Map.put(state, key, rest)}
        end
      end)

    case result do
      :ok -> {:ok, plan}
      {:reject, reason} -> {:error, {:invalid_plan, plan, reason}}
      error -> error
    end
  end

  defp build_plan(lesson, pages, examples, count, kept) do
    drafts =
      for n <- 1..count do
        case Enum.at(kept, n - 1) do
          nil ->
            CaptainHomework.Fixtures.question("q#{n}")
            |> Map.merge(%{
              "plan_id" => "q#{n}",
              "prompt" => "Question #{n}",
              "image_ids" => [],
              "source_page_ids" => [hd(pages).id],
              "support_id" => "",
              "response_effort" => "direct"
            })

          question ->
            question
        end
      end

    %{
      "version" => Plan.version(),
      "source_fingerprint" => Plan.fingerprint(lesson, pages, examples),
      "questions" => Enum.map(drafts, &Map.put(&1, "id", &1["plan_id"])),
      "supports" => [],
      "image_ids" => []
    }
  end

  def generate_planned(_, plan, slots, instructions, _) do
    Agent.get_and_update(__MODULE__, fn state ->
      state =
        state
        |> Map.update!(:repairs, &(&1 + 1))
        |> Map.update(:repair_instructions, [instructions], &(&1 ++ [instructions]))

      case Map.get(state, :repair_results, []) do
        [] -> {{:ok, slots, plan}, state}
        [result | rest] -> {result, Map.put(state, :repair_results, rest)}
      end
    end)
  end

  def audit_response_effort(questions, _context) do
    Agent.get_and_update(__MODULE__, fn state ->
      [result | remaining] = state.audits
      output = if result == :ok, do: {:ok, questions, []}, else: result
      {output, %{state | audits: remaining, audit_calls: state.audit_calls + 1}}
    end)
  end
end

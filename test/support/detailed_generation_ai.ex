defmodule CaptainHomework.DetailedGenerationAI do
  @behaviour CaptainHomework.AI
  alias CaptainHomework.Exams.Plan

  def transcribe(_, _), do: {:error, "unused"}
  def grade(_), do: {:error, "unused"}
  def generate(_, _, _, _, _, _), do: {:error, "unexpected legacy generation"}

  def plan_control(lesson, pages, examples, count, _, _, _) do
    record({:plan, count})

    questions =
      for n <- 1..count do
        CaptainHomework.Fixtures.question("q#{n}")
        |> Map.merge(%{
          "plan_id" => "q#{n}",
          "prompt" => "Question #{n}",
          "text" => "Document #{n}",
          "answer" => "Réponse #{n}",
          "objective" => "Notion #{n}",
          "skill" => "interpret",
          "expected_elements" => ["Fait #{n}"],
          "image_ids" => [],
          "image_regions" => [],
          "source_page_ids" => [hd(pages).id],
          "support_id" => "",
          "response_effort" => "direct",
          "answer_basis" => "document"
        })
      end

    {:ok,
     %{
       "version" => Plan.version(),
       "source_fingerprint" => Plan.fingerprint(lesson, pages, examples),
       "questions" => questions,
       "supports" => [],
       "image_ids" => []
     }}
  end

  def generate_planned(_, plan, slots, _, _) do
    record({:content_repair, Enum.map(slots, & &1["plan_id"])})
    repair(plan, slots, next(:content_repairs, :ok))
  end

  defp repair(plan, slots, :ok), do: {:ok, slots, plan}

  defp repair(plan, slots, {:change_prompt, prompt}) do
    repaired = Enum.map(slots, &Map.put(&1, "prompt", prompt))
    by_id = Map.new(repaired, &{&1["id"], &1})
    questions = Enum.map(plan["questions"], &Map.get(by_id, &1["id"], &1))
    {:ok, repaired, Map.put(plan, "questions", questions)}
  end

  defp repair(_, _, error), do: error

  def audit_response_effort(questions, context) do
    case audit_response_effort_detailed(questions, context) do
      {:ok, accepted, errors, _} -> {:ok, accepted, errors}
      error -> error
    end
  end

  def audit_response_effort_detailed(questions, context) do
    record({:audit, questions, context})

    case next(:audits, :ok) do
      :ok ->
        {:ok, questions ++ Map.get(context, :exposure_only_questions, []), [], %{}}

      {:reject, diagnostics} ->
        accepted = Enum.reject(questions, &Map.has_key?(diagnostics, &1["plan_id"]))
        errors = Enum.map(diagnostics, fn {id, d} -> "Question #{id} : #{d["reason"]}" end)
        {:ok, accepted, errors, diagnostics}

      error ->
        error
    end
  end

  defp record(call),
    do: Agent.update(__MODULE__, &Map.update!(&1, :calls, fn calls -> calls ++ [call] end))

  defp next(key, fallback) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state, key, []) do
        [] -> {fallback, state}
        [next | remaining] -> {next, Map.put(state, key, remaining)}
      end
    end)
  end
end

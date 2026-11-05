defmodule CaptainHomework.Exams.AuditCache do
  @moduledoc "Reuses semantic reviews while checking changed context for exposed answers."
  # Bump when audit rules change so persisted verdicts are checked again.
  @revision 6
  @content ~w(type prompt text audio_script options slots diagram answer rubric points image_ids image_regions support_text support_title response_effort answer_basis source_page_ids)
  @visible ~w(plan_id prompt text audio_script options slots diagram image_ids image_regions support_text)

  def revision, do: @revision

  def select(questions, cache, scope) do
    context = context_key(questions)

    Enum.reduce(questions, {[], [], []}, fn question, {targets, exposure, retained} ->
      entry = cache[question["plan_id"]] || %{}

      cond do
        entry["content"] != content_key(question, scope) ->
          {targets ++ [question], exposure, retained}

        question["answer_basis"] == "knowledge" and entry["context"] != context ->
          {targets, exposure ++ [question], retained}

        true ->
          {targets, exposure, retained ++ [question]}
      end
    end)
  end

  def record(accepted, context_questions, scope) do
    context = context_key(context_questions)

    Map.new(accepted, fn question ->
      {question["plan_id"], %{"content" => content_key(question, scope), "context" => context}}
    end)
  end

  defp content_key(question, scope), do: digest({@revision, scope, Map.take(question, @content)})

  defp context_key(questions) do
    questions
    |> Enum.map(&Map.take(&1, @visible))
    |> Enum.sort_by(& &1["plan_id"])
    |> digest()
  end

  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end

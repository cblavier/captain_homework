defmodule CaptainHomework.Exams.AnswerBasis do
  def targets(count, pages, types),
    do: CaptainHomework.Exams.Constraints.targets(count, types, pages).basis

  def valid?(questions, pages, types), do: validation_errors(questions, pages, types) == []

  def validation_errors(questions, pages, types, opts \\ []) do
    if Enum.any?(questions, &Map.has_key?(&1, "answer_basis")) do
      course_ids = pages |> Enum.filter(&(Map.get(&1, :kind) == "lesson")) |> MapSet.new(& &1.id)
      counts = Enum.frequencies_by(questions, & &1["answer_basis"])
      expected = targets(length(questions), pages, types)

      knowledge = Enum.filter(questions, &(&1["answer_basis"] == "knowledge"))

      no_course =
        knowledge
        |> Enum.reject(fn q ->
          Enum.any?(q["source_page_ids"], &MapSet.member?(course_ids, &1))
        end)
        |> Enum.map(& &1["id"])

      with_support =
        knowledge |> Enum.reject(&(&1["support_id"] == "")) |> Enum.map(& &1["id"])

      invalid_mode =
        questions
        |> Enum.reject(&(&1["answer_basis"] in ~w(knowledge document)))
        |> Enum.map(& &1["id"])

      []
      |> issue(
        Keyword.get(opts, :enforce_balance, true) and
          not Enum.all?(expected, fn {kind, count} -> Map.get(counts, kind, 0) == count end),
        "Répartition connaissances/documents incorrecte. Effectifs réels : #{Jason.encode!(counts)} ; attendus : #{Jason.encode!(expected)}."
      )
      |> issue(
        no_course != [],
        "Questions de connaissances sans source de leçon : #{Enum.join(no_course, ", ")}."
      )
      |> issue(
        with_support != [],
        "Questions de connaissances avec un support visible à retirer : #{Enum.join(with_support, ", ")}."
      )
      |> issue(
        invalid_mode != [],
        "Mode de résolution inconnu : #{Enum.join(invalid_mode, ", ")}."
      )
    else
      []
    end
  end

  defp issue(issues, true, message), do: issues ++ [message]
  defp issue(issues, false, _), do: issues

  def review_ok?(q, review) do
    if Map.has_key?(q, "answer_basis") do
      review["actual_basis"] == q["answer_basis"] and
        (q["answer_basis"] != "knowledge" or review["answer_exposed"] == false)
    else
      true
    end
  end
end

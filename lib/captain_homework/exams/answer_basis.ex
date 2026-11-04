defmodule CaptainHomework.Exams.AnswerBasis do
  def valid?(questions, pages, types), do: validation_errors(questions, pages, types) == []

  def validation_errors(questions, pages, _types, _opts \\ []) do
    if Enum.any?(questions, &Map.has_key?(&1, "answer_basis")) do
      course_ids = pages |> Enum.filter(&(Map.get(&1, :kind) == "lesson")) |> MapSet.new(& &1.id)

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
      case {q["answer_basis"], review["actual_basis"]} do
        {"knowledge", "knowledge"} -> review["answer_exposed"] == false
        {"document", "document"} -> true
        # Naming what is visible also requires learned vocabulary. This label
        # disagreement alone is not a defect; consistency is reviewed separately.
        {"document", "knowledge"} -> (q["image_ids"] || []) != []
        _ -> false
      end
    else
      true
    end
  end
end

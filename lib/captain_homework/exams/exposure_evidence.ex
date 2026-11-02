defmodule CaptainHomework.Exams.ExposureEvidence do
  @moduledoc "Requires a visible source before an audit can flag an exposed answer."

  def verify(reviews, questions, supports, images) when is_list(reviews) do
    Enum.map(reviews, fn review ->
      if review["answer_exposed"] == true and
           not proven?(review, questions, supports, images) do
        Map.put(review, "answer_exposed", false)
      else
        review
      end
    end)
  end

  def verify(reviews, _, _, _), do: reviews

  defp proven?(review, questions, supports, images) do
    source = review["exposure_source_id"]
    quote = normalize(review["exposure_quote"])

    if quote == "" do
      false
    else
      case source do
        "question:" <> id ->
          case Enum.find(questions, &(&1["plan_id"] == id)) do
            nil -> false
            question -> contains?(question_texts(question, review["plan_id"]), quote)
          end

        "support:" <> id ->
          case Enum.find(supports, &(&1["id"] == id)) do
            nil -> false
            support -> contains?([support["text"]], quote)
          end

        "image:" <> id ->
          # A pixel-level visual observation cannot be checked by string matching.
          # Require a nonempty observation and an image actually shown to the student.
          Enum.any?(images, &(&1.id == id))

        _ ->
          false
      end
    end
  end

  defp question_texts(question, reviewed_id) do
    options =
      if question["plan_id"] == reviewed_id and question["type"] == "mcq",
        do: [],
        else: question["options"] || []

    labels =
      case question["diagram"] do
        %{"nodes" => nodes} -> Enum.map(nodes, & &1["label"])
        _ -> []
      end

    [question["prompt"], question["text"]] ++ options ++ labels
  end

  defp contains?(texts, quote),
    do: Enum.any?(texts, &String.contains?(normalize(&1), quote))

  defp normalize(value) when is_binary(value),
    do: value |> String.replace(~r/\s+/u, " ") |> String.trim()

  defp normalize(_), do: ""
end

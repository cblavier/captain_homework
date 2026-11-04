defmodule CaptainHomework.Exams.Language do
  # Locate exact excerpts server-side, never trust model-supplied offsets or HTML.
  def validate(answer, errors) when is_list(errors) do
    fields = fields(answer) |> Map.new()

    errors
    |> Enum.take(80)
    |> Enum.reduce([], fn error, accepted ->
      with %{
             "field" => field,
             "original" => original,
             "replacement" => replacement,
             "occurrence" => occurrence,
             "explanation" => explanation
           } <- error,
           text when is_binary(text) <- fields[field],
           true <-
             is_binary(original) and original != "" and
               is_binary(replacement) and replacement != original and
               is_binary(explanation) and String.trim(explanation) != "" and
               String.length(explanation) <= 2000 and String.length(replacement) <= 2000,
           true <- occurrence == 1,
           [{start, length}] <- :binary.matches(text, original),
           true <-
             String.valid?(binary_part(text, 0, start)) and
               String.valid?(binary_part(text, start, length)),
           false <-
             Enum.any?(accepted, fn e ->
               e["field"] == field and start < e["start"] + e["length"] and
                 e["start"] < start + length
             end) do
        accepted ++
          [
            %{
              "field" => field,
              "original" => original,
              "replacement" => replacement,
              "explanation" => explanation,
              "start" => start,
              "length" => length
            }
          ]
      else
        _ -> accepted
      end
    end)
  end

  def validate(_, _), do: []

  def fields(answer) when is_map(answer), do: Enum.sort(answer)
  def fields(answer) when is_binary(answer), do: [{"", answer}]
  def fields(_), do: [{"", ""}]

  def rows(answer, errors) do
    for {field, text} <- fields(answer) do
      relevant =
        errors
        |> Enum.with_index()
        |> Enum.filter(fn {e, _} -> e["field"] == field end)
        |> Enum.sort_by(fn {e, _} -> e["start"] end)

      {segments, offset} =
        Enum.reduce(relevant, {[], 0}, fn {error, index}, {segments, offset} ->
          prefix = binary_part(text, offset, error["start"] - offset)

          {segments ++
             [%{text: prefix, error: nil}, %{text: error["original"], error: error, index: index}],
           error["start"] + error["length"]}
        end)

      suffix = binary_part(text, offset, byte_size(text) - offset)

      %{
        field: field,
        segments:
          segments ++ [%{text: if(text == "", do: "Sans réponse", else: suffix), error: nil}]
      }
    end
  end
end

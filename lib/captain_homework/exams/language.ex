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
           false <- duplicates_context?(text, start, length, original, replacement),
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
        |> Enum.filter(fn {e, _} ->
          e["field"] == field and
            not duplicates_context?(
              text,
              e["start"],
              e["length"],
              e["original"],
              e["replacement"]
            )
        end)
        |> Enum.sort_by(fn {e, _} -> e["start"] end)

      {segments, offset} =
        Enum.reduce(relevant, {[], 0}, fn {error, index}, {segments, offset} ->
          prefix = binary_part(text, offset, error["start"] - offset)

          {segments ++ [%{text: prefix, error: nil}] ++ changed_segments(error, index),
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

  # Only reject an expansion that copies words from immediately outside the excerpt.
  # This deliberately does not reject repetitions already written by the pupil,
  # or grammatical changes within the excerpt (e.g. "nous nous sommes lavés").
  defp duplicates_context?(text, start, length, original, replacement) do
    prefix = binary_part(text, 0, start)
    suffix = binary_part(text, start + length, byte_size(text) - start - length)

    (String.starts_with?(replacement, original) and
       copied_words?(String.replace_prefix(replacement, original, ""), suffix, :after)) or
      (String.ends_with?(replacement, original) and
         copied_words?(String.replace_suffix(replacement, original, ""), prefix, :before))
  end

  defp copied_words?(added, context, side) do
    # Require whole added words separated from the retained excerpt. In particular,
    # a plural suffix or an accent correction must never be mistaken for a copy.
    separated? =
      if side == :after,
        do: Regex.match?(~r/^\s/u, added),
        else: Regex.match?(~r/\s$/u, added)

    words = String.split(added)

    if separated? and words != [] and
         Enum.all?(words, &Regex.match?(~r/^[\p{L}\p{M}\p{N}]+$/u, &1)) do
      phrase = Enum.map_join(words, "\\s+", &Regex.escape/1)

      pattern =
        if side == :after,
          do: "^\\s+" <> phrase <> "(?![\\p{L}\\p{M}\\p{N}])",
          else: "(?<![\\p{L}\\p{M}\\p{N}])" <> phrase <> "\\s+$"

      Regex.match?(Regex.compile!(pattern, "u"), context)
    else
      false
    end
  end

  defp changed_segments(error, index) do
    error["original"]
    |> tokens()
    |> List.myers_difference(tokens(error["replacement"]))
    |> Enum.chunk_by(fn {operation, _} -> operation == :eq end)
    |> Enum.with_index()
    |> Enum.map(fn
      {[{:eq, tokens}], _} ->
        %{text: Enum.join(tokens), error: nil}

      {changes, part} ->
        %{
          text: diff_text(changes, :del),
          replacement: diff_text(changes, :ins),
          error: error,
          index: index,
          part: part
        }
    end)
  end

  defp tokens(text), do: Regex.scan(~r/[\p{L}\p{M}\p{N}]+|\s+|[^\s]/u, text) |> List.flatten()

  defp diff_text(changes, operation) do
    for {^operation, tokens} <- changes, into: "", do: Enum.join(tokens)
  end
end

defmodule CaptainHomework.Exams.SupportGroups do
  @moduledoc "Groups adjacent questions sharing a document without changing answers or grading."

  def build(questions) do
    questions
    |> Enum.with_index(1)
    |> Enum.reduce([], fn {question, index}, groups ->
      source = source_support(question)

      case groups do
        [group | rest] ->
          if compatible?(group.support, source) do
            support =
              if String.length(source["text"] || "") >
                   String.length(group.support["text"] || ""), do: source, else: group.support

            [
              %{
                group
                | support: support,
                  questions: group.questions ++ [{question, index}],
                  shared?: true
              }
              | rest
            ]
          else
            [new_group(question, index) | groups]
          end

        [] ->
          [new_group(question, index)]
      end
    end)
    |> Enum.reverse()
  end

  defp new_group(question, index),
    do: %{
      support: source_support(question),
      questions: [{question, index}],
      shared?: is_binary(question["support_text"])
    }

  def question_text_visible?(question, shared?) do
    question["text"] not in [nil, ""] and
      (not shared? or
         (is_binary(question["support_text"]) and question["text"] != question["support_text"]))
  end

  defp source_support(%{"support_text" => text} = question) when is_binary(text),
    do: Map.put(question, "text", text)

  defp source_support(question), do: question

  defp compatible?(a, b) do
    a["type"] not in ["cloze", "diagram"] and b["type"] not in ["cloze", "diagram"] and
      a["support_id"] == b["support_id"] and
      image_key(a) == image_key(b) and
      compatible_text?(a["text"] || "", b["text"] || "", image_key(a) != [])
  end

  defp compatible_text?(a, b, images?) do
    a = normalize(a)
    b = normalize(b)

    cond do
      a == "" and b == "" ->
        images?

      a == b ->
        true

      min(String.length(a), String.length(b)) < 200 ->
        false

      true ->
        {short, long} = if String.length(a) < String.length(b), do: {a, b}, else: {b, a}
        String.length(short) / String.length(long) >= 0.8 and String.contains?(long, short)
    end
  end

  defp image_key(q) do
    ids =
      case q["image_ids"] || [] do
        [] -> Enum.map(q["images"] || [], & &1["storage_key"])
        ids -> ids
      end

    regions = Enum.sort(Map.get(q, "image_regions", []))
    Enum.map(ids, &{&1, regions}) |> Enum.sort()
  end

  defp normalize(text) do
    text
    |> String.normalize(:nfc)
    |> String.replace(~r/[«»“”"]/u, "")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end
end

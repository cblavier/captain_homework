defmodule CaptainHomework.AI.RepairContext do
  @moduledoc "Selects repair evidence while retaining the visible context of accepted questions."
  @visible_fields ~w(id plan_id type prompt text audio_script options slots diagram image_ids image_regions support_id support_text objective skill expected_elements)

  def build(plan, rejected, images) do
    rejected_ids = MapSet.new(rejected, & &1["id"])
    retained = Enum.reject(plan["questions"] || [], &MapSet.member?(rejected_ids, &1["id"]))
    source_ids = Enum.flat_map(rejected, &Map.get(&1, "source_page_ids", []))
    kinds = decode(plan["context"])["source_kinds"] || %{}

    missing_course? =
      Enum.any?(rejected, fn question ->
        question["answer_basis"] == "knowledge" and
          not Enum.any?(question["source_page_ids"] || [], &(kinds[&1] == "lesson"))
      end)

    course_ids = if missing_course?, do: for({id, "lesson"} <- kinds, do: id), else: []
    # Standalone figures were already selected under the author's exclusions.
    # Supply alternatives when repairing an illustrated question so an ambiguous
    # image can be replaced instead of repeatedly rewriting around it.
    alternative_ids =
      if Enum.any?(rejected, &((Map.get(&1, "image_ids") || []) != [])) do
        (decode(plan["context"])["catalogue"] || [])
        |> Enum.filter(&(&1["kind"] == "visual"))
        |> Enum.flat_map(& &1["source_page_ids"])
      else
        []
      end

    content =
      filter_catalogue(plan["context"], source_ids ++ course_ids ++ alternative_ids,
        fallback: true
      )

    catalogue = decode(content)
    support_ids = MapSet.new(plan["questions"] || [], & &1["support_id"])
    supports = Enum.filter(plan["supports"] || [], &MapSet.member?(support_ids, &1["id"]))

    visible_ids = Enum.flat_map(retained ++ rejected ++ supports, &Map.get(&1, "image_ids", []))
    candidate_ids = Enum.flat_map(catalogue["catalogue"] || [], & &1["visual_page_ids"])
    needed = MapSet.new(visible_ids ++ candidate_ids)

    %{
      content: content,
      images: Enum.filter(images, &MapSet.member?(needed, &1.id)),
      retained: Enum.map(retained, &visible_question/1),
      supports: supports
    }
  end

  def visible_question(question) do
    question
    |> Map.take(@visible_fields)
    |> compact_support()
  end

  def compact_support(question) do
    if is_binary(question["support_id"]) and question["support_id"] != "" do
      question =
        if is_binary(question["support_text"]) and question["text"] == question["support_text"],
          do: Map.put(question, "text", ""),
          else: question

      Map.delete(question, "support_text")
    else
      question
    end
  end

  def filter_catalogue(content, source_ids, opts \\ []) do
    case decode(content) do
      %{"catalogue" => entries} = context when is_list(entries) ->
        wanted = MapSet.new(source_ids)

        selected =
          Enum.filter(entries, fn entry ->
            Enum.any?(entry["source_page_ids"], &MapSet.member?(wanted, &1))
          end)

        selected =
          if selected == [] and Keyword.get(opts, :fallback, false), do: entries, else: selected

        dependency_ids = MapSet.new(Enum.flat_map(selected, & &1["source_page_ids"]))

        facts =
          Enum.filter(entries, fn entry ->
            entry["kind"] == "knowledge" and
              Enum.any?(entry["source_page_ids"], &MapSet.member?(dependency_ids, &1))
          end)

        selected = Enum.uniq(selected ++ facts)
        ids = MapSet.new(Enum.flat_map(selected, & &1["source_page_ids"]))

        kinds =
          Map.filter(context["source_kinds"] || %{}, fn {id, _} -> MapSet.member?(ids, id) end)

        context
        |> Map.put("catalogue", selected)
        |> Map.put("source_kinds", kinds)
        |> Jason.encode!()

      _ ->
        content || "{}"
    end
  end

  defp decode(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, value} when is_map(value) -> value
      _ -> %{}
    end
  end

  defp decode(_), do: %{}
end

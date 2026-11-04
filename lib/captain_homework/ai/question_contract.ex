defmodule CaptainHomework.AI.QuestionContract do
  @moduledoc "The application owns question identities; the model fills named entries."
  @content_fields ~w(type prompt text audio_script options slots diagram answer rubric points image_ids image_regions)

  def content_fields, do: @content_fields

  def frozen(kept),
    do:
      Map.new(kept, fn question ->
        # Retried questions carry their document separately from their own task.
        # Preserve both even when they become autonomous in the new control.
        {question["plan_id"],
         Map.take(question, @content_fields ++ ["support_text", "support_title"])
         |> Map.put_new("image_ids", [])
         |> Map.put_new("image_regions", [])
         |> Map.put("support_id", "")}
      end)

  def ids(count, kept) do
    retained = Enum.map(kept, & &1["plan_id"])

    fresh =
      Stream.iterate(1, &(&1 + 1))
      |> Stream.map(&"q#{&1}")
      |> Stream.reject(&(&1 in retained))
      |> Enum.take(max(count - length(retained), 0))

    retained ++ fresh
  end

  def schema(properties, ids, frozen \\ %{}) do
    properties = Map.drop(properties, ["id", "plan_id", "image_regions"])

    object(
      Map.new(ids, fn id ->
        {id, object(Map.drop(properties, Map.keys(Map.get(frozen, id, %{}))))}
      end)
    )
  end

  def decode(raw, ids, frozen \\ %{})

  def decode(%{"questions" => questions, "supports" => supports}, ids, frozen)
      when is_map(questions) and is_list(supports) do
    if Enum.sort(Map.keys(questions)) == Enum.sort(ids) and
         Enum.all?(questions, fn {_, q} -> is_map(q) end) and Enum.all?(supports, &is_map/1) do
      {:ok,
       %{
         "questions" =>
           Enum.map(ids, fn id ->
             questions[id]
             |> Map.put("image_regions", [])
             |> Map.merge(Map.get(frozen, id, %{}))
             |> Map.merge(%{"id" => id, "plan_id" => id})
           end),
         "supports" => Enum.map(supports, &Map.put(&1, "image_regions", []))
       }}
    else
      {:error, "Les entrées reçues ne correspondent pas exactement aux identifiants demandés."}
    end
  end

  def decode(_, _, _), do: {:error, "Objet de questions indexées par leurs identifiants attendu."}

  defp object(properties),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => Map.keys(properties),
      "additionalProperties" => false
    }
end

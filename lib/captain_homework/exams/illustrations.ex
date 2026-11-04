defmodule CaptainHomework.Exams.Illustrations do
  alias CaptainHomework.{ImageCrops, Uploads}

  def extracted?(page),
    do: page.kind == "illustration" and is_binary(Map.get(page, :extracted_from_id))

  def resource_content_page?(page), do: page.kind == "resource" or extracted?(page)

  def sources(lesson) do
    ready_ids = ready_resource_ids(lesson)

    Enum.filter(lesson.pages, fn page ->
      page.kind in ["resource", "illustration"] and page.resource_id in ready_ids and
        String.starts_with?(page.content_type, "image/")
    end)
  end

  def content_pages(lesson) do
    ready_ids = ready_resource_ids(lesson)

    Enum.filter(
      lesson.pages,
      &(&1.kind == "lesson" or (resource_content_page?(&1) and &1.resource_id in ready_ids))
    )
  end

  def priority_exercises?(lesson) do
    Enum.any?(
      content_pages(lesson),
      &(resource_content_page?(&1) and &1.document_kind in ["assessment", "activity"])
    )
  end

  def resources_pending?(lesson), do: Enum.any?(lesson.resources, &(&1.status != "ready"))

  defp ready_resource_ids(lesson),
    do: for(resource <- lesson.resources, resource.status == "ready", do: resource.id)

  def validate(candidates, lesson) do
    allowed = Map.new(sources(lesson), &{&1.id, &1})

    Enum.reduce(candidates, {[], []}, fn q, {valid, errors} ->
      ids = Map.get(q, "image_ids", [])

      if ImageCrops.validate(ids, Map.get(q, "image_regions", [])) == :ok and
           Enum.all?(
             ids,
             &(Map.has_key?(allowed, &1) and File.regular?(Uploads.path(allowed[&1].storage_key)))
           ) do
        {valid ++ [Map.delete(q, "images")], errors}
      else
        {valid,
         errors ++
           [
             "Illustration inconnue ou indisponible : utilise uniquement les identifiants des images ressources fournies."
           ]}
      end
    end)
  end

  def snapshot(question, lesson) do
    allowed = Map.new(sources(lesson), &{&1.id, &1})

    assets =
      Enum.map(Enum.uniq(Map.get(question, "image_ids", [])), fn id ->
        page = Map.fetch!(allowed, id)
        region = Enum.find(Map.get(question, "image_regions", []), &(&1["image_id"] == id))

        %{
          "storage_key" => page.storage_key,
          "content_type" => page.content_type,
          "source_page_id" => id,
          "crop" => region
        }
      end)
      |> copy_assets(true)

    Map.put(question, "images", assets)
  end

  def copy_retry(question) do
    copied = Map.put(question, "images", copy_assets(Map.get(question, "images", [])))

    try do
      CaptainHomework.Exams.Listening.copy(copied)
    rescue
      error ->
        delete_exam_images(%{questions: [Map.delete(copied, "audio")]})
        reraise error, __STACKTRACE__
    end
  end

  def copy_questions(questions) do
    Enum.reduce(questions, [], fn question, copied ->
      try do
        copy =
          if Map.has_key?(question, "images"),
            do: copy_retry(question),
            else: CaptainHomework.Exams.Listening.copy(question)

        copied ++ [copy]
      rescue
        error ->
          delete_exam_images(%{questions: copied})
          reraise error, __STACKTRACE__
      end
    end)
  end

  def snapshot_questions(questions, lesson) do
    Enum.reduce(questions, [], fn question, copied ->
      try do
        copied ++ [snapshot(question, lesson)]
      rescue
        error ->
          delete_exam_images(%{questions: copied})
          Enum.each(questions, &CaptainHomework.Exams.Listening.delete/1)
          reraise error, __STACKTRACE__
      end
    end)
  end

  defp copy_assets(assets, crop? \\ false) do
    Enum.reduce(assets, [], fn asset, copied ->
      try do
        copied ++ [copy(asset, crop?)]
      rescue
        error ->
          Enum.each(copied, &File.rm(Uploads.path(&1["storage_key"])))
          reraise error, __STACKTRACE__
      end
    end)
  end

  defp copy(%{"crop" => region} = asset, true) when is_map(region) do
    id = Ecto.UUID.generate()
    key = "question-#{id}.png"

    with {:ok, data} <- ImageCrops.render(Uploads.path(asset["storage_key"]), region),
         :ok <- File.write(Uploads.path(key), data) do
      %{
        "id" => id,
        "storage_key" => key,
        "content_type" => "image/png",
        "source_page_id" => asset["source_page_id"],
        "crop" => region
      }
    else
      error ->
        File.rm(Uploads.path(key))
        raise "Impossible de préparer l’illustration recadrée : #{inspect(error)}"
    end
  end

  defp copy(asset, _) do
    id = Ecto.UUID.generate()
    key = "question-#{id}#{Path.extname(asset["storage_key"])}"

    case File.cp(Uploads.path(asset["storage_key"]), Uploads.path(key)) do
      :ok ->
        asset
        |> Map.take(["source_page_id", "crop"])
        |> Map.merge(%{"id" => id, "storage_key" => key, "content_type" => asset["content_type"]})

      {:error, reason} ->
        File.rm(Uploads.path(key))

        raise File.CopyError,
          reason: reason,
          source: Uploads.path(asset["storage_key"]),
          destination: Uploads.path(key),
          on: ""
    end
  end

  def delete_exam_images(exam) do
    Enum.each(exam.questions, &CaptainHomework.Exams.Listening.delete/1)

    for question <- exam.questions,
        asset <- Map.get(question, "images", []),
        do: File.rm(Uploads.path(asset["storage_key"]))

    :ok
  end
end

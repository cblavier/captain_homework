defmodule CaptainHomework.Exams.Illustrations do
  alias CaptainHomework.Uploads

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
      &(&1.kind == "lesson" or (&1.kind == "resource" and &1.resource_id in ready_ids))
    )
  end

  def priority_exercises?(lesson) do
    Enum.any?(
      content_pages(lesson),
      &(&1.kind == "resource" and &1.document_kind in ["assessment", "activity"])
    )
  end

  def resources_pending?(lesson), do: Enum.any?(lesson.resources, &(&1.status != "ready"))

  defp ready_resource_ids(lesson),
    do: for(resource <- lesson.resources, resource.status == "ready", do: resource.id)

  def validate(candidates, lesson) do
    allowed = Map.new(sources(lesson), &{&1.id, &1})

    Enum.reduce(candidates, {[], []}, fn q, {valid, errors} ->
      ids = Map.get(q, "image_ids", [])

      if Enum.all?(
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
        %{"storage_key" => page.storage_key, "content_type" => page.content_type}
      end)
      |> copy_assets()

    Map.put(question, "images", assets)
  end

  def copy_retry(question) do
    Map.put(question, "images", copy_assets(Map.get(question, "images", [])))
  end

  def snapshot_questions(questions, lesson) do
    Enum.reduce(questions, [], fn question, copied ->
      try do
        copied ++ [snapshot(question, lesson)]
      rescue
        error ->
          delete_exam_images(%{questions: copied})
          reraise error, __STACKTRACE__
      end
    end)
  end

  defp copy_assets(assets) do
    Enum.reduce(assets, [], fn asset, copied ->
      try do
        copied ++ [copy(asset)]
      rescue
        error ->
          Enum.each(copied, &File.rm(Uploads.path(&1["storage_key"])))
          reraise error, __STACKTRACE__
      end
    end)
  end

  defp copy(asset) do
    id = Ecto.UUID.generate()
    key = "question-#{id}#{Path.extname(asset["storage_key"])}"

    case File.cp(Uploads.path(asset["storage_key"]), Uploads.path(key)) do
      :ok ->
        %{"id" => id, "storage_key" => key, "content_type" => asset["content_type"]}

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
    for question <- exam.questions,
        asset <- Map.get(question, "images", []),
        do: File.rm(Uploads.path(asset["storage_key"]))

    :ok
  end
end

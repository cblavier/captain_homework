defmodule CaptainHomework.Resources do
  @moduledoc "Import and OCR of lesson reference documents."
  import Ecto.Query
  alias CaptainHomework.{AI, Repo, Study, Uploads}
  alias CaptainHomework.Study.{Resource, Page}
  alias CaptainHomework.Resources.{Download, Documents}

  @processing_timeout 2 * 60 * 60

  def get!(profile_id, id) do
    Repo.one!(
      from r in Resource,
        join: l in assoc(r, :lesson),
        where: r.id == ^id and l.profile_id == ^profile_id
    )
  end

  def create_upload(profile_id, lesson_id, temp, filename) do
    lesson = Study.get_lesson!(profile_id, lesson_id)

    with {:ok, type, ext} <- upload_type(temp),
         {:ok, key} <- copy_upload(temp, ext) do
      insert(%Resource{
        lesson_id: lesson.id,
        filename: Path.basename(filename),
        storage_key: key,
        content_type: type
      })
    end
  end

  defp upload_type(path) do
    with {:ok, %{type: :regular}} <- File.stat(path),
         {:ok, header} when is_binary(header) <-
           File.open(path, [:read, :binary], &IO.binread(&1, 512)),
         {:ok, type, ext} <- Documents.type(header) do
      {:ok, type, ext}
    else
      _ -> {:error, "Choisis un PDF, JPEG, PNG ou WebP."}
    end
  end

  defp copy_upload(path, ext) do
    key = Ecto.UUID.generate() <> ext

    with :ok <- File.mkdir_p(Uploads.directory()),
         :ok <- File.cp(path, Uploads.path(key)) do
      {:ok, key}
    else
      _ ->
        File.rm(Uploads.path(key))
        {:error, "Le fichier n’a pas pu être enregistré. Réessaie."}
    end
  end

  def create_url(profile_id, lesson_id, url) do
    lesson = Study.get_lesson!(profile_id, lesson_id)

    with {:ok, uri} <- Download.validate_url(url) do
      name = uri.path |> to_string() |> Path.basename()
      name = if name in ["", ".", "/"], do: uri.host, else: name
      insert(%Resource{lesson_id: lesson.id, source_url: URI.to_string(uri), filename: name})
    end
  end

  defp insert(resource) do
    case Repo.insert(resource) do
      {:ok, resource} ->
        {:ok, resource}

      error ->
        if resource.storage_key, do: File.rm(Uploads.path(resource.storage_key))
        error
    end
  end

  def process(id) do
    case Repo.get(Resource, id) do
      nil ->
        {:error, :not_found}

      resource ->
        now = DateTime.utc_now()
        cutoff = DateTime.add(now, -@processing_timeout)

        {claimed, _} =
          Repo.update_all(
            from(r in Resource,
              where:
                r.id == ^id and r.status != "ready" and
                  (is_nil(r.processing_started_at) or r.processing_started_at < ^cutoff)
            ),
            set: [processing_started_at: now, status: "processing", error: nil]
          )

        if claimed == 1, do: process_resource(resource), else: {:error, :already_processing}
    end
  end

  defp process_resource(resource) do
    # Completed pages survive failed attempts so long documents do not restart their OCR.
    resource =
      resource |> Ecto.Changeset.change(status: "processing", error: nil) |> Repo.update!()

    CaptainHomework.ProcessingProgress.update(resource, 5, "Import du document")

    result =
      with {:ok, resource} <- obtain_original(resource),
           {:ok, resource} <- name_document(resource),
           :ok <-
             CaptainHomework.ProcessingProgress.update(
               resource,
               20,
               "Extraction des pages et illustrations"
             ),
           {:ok, parts} <- Documents.extract(resource),
           :ok <- import_parts(resource, parts),
           {:ok, _catalogue} <- CaptainHomework.Catalogues.prepare_resource(resource) do
        {:ok, resource}
      end

    case result do
      {:ok, resource} -> finish(resource, "ready", nil)
      {:error, reason} -> finish(resource, "error", message(reason))
    end
  rescue
    _ ->
      finish(
        resource,
        "error",
        "Le document n’a pas pu être traité. Vérifie son format puis réessaie."
      )
  end

  def retry(profile_id, id) do
    resource = get!(profile_id, id)
    cutoff = DateTime.add(DateTime.utc_now(), -@processing_timeout)

    {count, _} =
      Repo.update_all(
        from(r in Resource,
          where:
            r.id == ^resource.id and
              (r.status == "error" or
                 (r.status == "processing" and
                    (is_nil(r.processing_started_at) or r.processing_started_at < ^cutoff)))
        ),
        set: [status: "processing", error: nil, processing_started_at: nil]
      )

    if count == 1,
      do: {:ok, Repo.get!(Resource, id)},
      else: {:error, "Le document est déjà traité ou en cours de traitement."}
  end

  def delete(profile_id, id) do
    resource = get!(profile_id, id)
    pages = Repo.all(from p in Page, where: p.resource_id == ^resource.id)

    with {:ok, deleted} <- Repo.delete(resource) do
      Enum.each(pages, &File.rm(Uploads.path(&1.storage_key)))
      if deleted.storage_key, do: File.rm(Uploads.path(deleted.storage_key))
      broadcast(deleted)
      {:ok, deleted}
    end
  end

  defp obtain_original(%{storage_key: key} = resource) when is_binary(key), do: {:ok, resource}

  defp obtain_original(resource) do
    with {:ok, data, type, final_url} <- Download.fetch(resource.source_url),
         {:ok, type, ext} <- Documents.type(data, type) do
      key = store(data, ext)

      case resource
           |> Ecto.Changeset.change(storage_key: key, content_type: type, source_url: final_url)
           |> Repo.update() do
        {:ok, resource} ->
          {:ok, resource}

        error ->
          File.rm(Uploads.path(key))
          error
      end
    end
  end

  defp name_document(%{source_url: url} = resource) when is_binary(url) do
    case Documents.title(resource) do
      nil ->
        {:ok, resource}

      title ->
        filename =
          if String.ends_with?(String.downcase(title), ".pdf"), do: title, else: title <> ".pdf"

        resource |> Ecto.Changeset.change(filename: filename) |> Repo.update()
    end
  end

  defp name_document(resource), do: {:ok, resource}

  defp import_parts(resource, parts) do
    lesson = Repo.get!(Study.Lesson, resource.lesson_id)
    expected = MapSet.new(parts, &{&1.kind, &1.name})
    existing = Repo.all(from p in Page, where: p.resource_id == ^resource.id)

    {completed_pages, obsolete_pages} =
      Enum.split_with(existing, fn page ->
        MapSet.member?(expected, {page.kind, page.filename}) and page.status == "ready" and
          File.regular?(Uploads.path(page.storage_key))
      end)

    Enum.each(obsolete_pages, &Study.delete_page/1)

    completed =
      MapSet.new(completed_pages, &{&1.kind, &1.filename})

    total = Enum.count(parts, &(&1.kind != "illustration"))
    done = Enum.count(completed_pages, &(&1.kind != "illustration"))
    report_ocr_progress(resource, done, total)

    result =
      parts
      |> Enum.reject(&MapSet.member?(completed, {&1.kind, &1.name}))
      |> Task.async_stream(
        &analyze_part/1,
        max_concurrency: 3,
        ordered: true,
        timeout: 180_000,
        on_timeout: :kill_task
      )
      |> Enum.reduce_while({:ok, done}, fn
        {:ok, {part, {:ok, result}}}, {:ok, done} ->
          case persist_part(lesson, resource, part, result["text"], result["document_kind"]) do
            {:ok, _} ->
              done = done + if(part.kind == "illustration", do: 0, else: 1)
              if part.kind != "illustration", do: report_ocr_progress(resource, done, total)
              {:cont, {:ok, done}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end

        {:ok, {_part, {:error, reason}}}, _ ->
          {:halt, {:error, reason}}

        {:exit, _}, _ ->
          {:halt,
           {:error,
            "La lecture d’une page a été interrompue. Réessaie : les pages déjà reconnues sont conservées."}}
      end)

    case result do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp report_ocr_progress(resource, done, total) do
    percent = 30 + round(55 * done / max(total, 1))

    CaptainHomework.ProcessingProgress.update(
      resource,
      percent,
      "Lecture OCR — #{done}/#{total} pages"
    )
  end

  defp analyze_part(part) do
    result =
      if part.kind == "illustration",
        do: {:ok, %{"text" => "", "document_kind" => "other"}},
        else: AI.analyze_resource(part.data, part.type)

    {part, result}
  rescue
    _ ->
      {part,
       {:error,
        "La lecture d’une page a échoué. Réessaie : les pages déjà reconnues sont conservées."}}
  end

  defp persist_part(lesson, resource, part, text, kind) do
    key = store(part.data, part.ext)

    try do
      case Study.add_page(lesson, %{
             resource_id: resource.id,
             kind: part.kind,
             filename: part.name,
             storage_key: key,
             content_type: part.type,
             text: text || "",
             document_kind: kind || "other",
             status: "ready"
           }) do
        {:ok, page} ->
          {:ok, page}

        error ->
          File.rm(Uploads.path(key))
          error
      end
    rescue
      exception ->
        File.rm(Uploads.path(key))
        reraise exception, __STACKTRACE__
    end
  end

  defp finish(resource, status, error) do
    case Repo.get(Resource, resource.id) do
      nil ->
        {:error, :not_found}

      current ->
        result =
          current
          |> Ecto.Changeset.change(
            status: status,
            error: error,
            processing_started_at: nil,
            processing_stage: nil,
            processing_progress: if(status == "ready", do: 100, else: current.processing_progress)
          )
          |> Repo.update()

        broadcast(current)
        result
    end
  end

  defp store(data, ext) do
    File.mkdir_p!(Uploads.directory())
    key = Ecto.UUID.generate() <> ext
    File.write!(Uploads.path(key), data)
    key
  end

  defp message(message) when is_binary(message), do: message
  defp message(_), do: "Le document n’a pas pu être traité. Réessaie."

  defp broadcast(resource),
    do:
      Phoenix.PubSub.broadcast(
        CaptainHomework.PubSub,
        "lesson:#{resource.lesson_id}",
        :lesson_updated
      )
end

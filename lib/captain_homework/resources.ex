defmodule CaptainHomework.Resources do
  @moduledoc "Import and OCR of lesson reference documents."
  import Ecto.Query
  alias CaptainHomework.{AI, Repo, Study, Uploads}
  alias CaptainHomework.Study.{Resource, Page}
  alias CaptainHomework.Resources.{Download, Documents}

  @max_bytes 20 * 1024 * 1024
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

    with {:ok, %{size: size}} when size <= @max_bytes <- File.stat(temp),
         {:ok, data} <- File.read(temp),
         {:ok, type, ext} <- Documents.type(data) do
      key = store(data, ext)

      insert(%Resource{
        lesson_id: lesson.id,
        filename: Path.basename(filename),
        storage_key: key,
        content_type: type
      })
    else
      _ -> {:error, "Choisis un PDF, JPEG, PNG ou WebP de moins de 20 Mo."}
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
    # A retry replaces incomplete OCR output; only ready resources are used by generation.
    remove_pages(resource.id)

    resource =
      resource |> Ecto.Changeset.change(status: "processing", error: nil) |> Repo.update!()

    broadcast(resource)

    result =
      with {:ok, resource} <- obtain_original(resource),
           {:ok, parts} <- Documents.extract(resource),
           :ok <- import_parts(resource, parts) do
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

  defp import_parts(resource, parts) do
    lesson = Repo.get!(Study.Lesson, resource.lesson_id)

    Enum.reduce_while(parts, :ok, fn part, _ ->
      result =
        if part.kind == "illustration" do
          persist_part(lesson, resource, part, "", "other")
        else
          with {:ok, result} <- AI.analyze_resource(part.data, part.type) do
            persist_part(lesson, resource, part, result["text"], result["document_kind"])
          end
        end

      case result do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
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
          |> Ecto.Changeset.change(status: status, error: error, processing_started_at: nil)
          |> Repo.update()

        broadcast(current)
        result
    end
  end

  defp remove_pages(id) do
    pages = Repo.all(from p in Page, where: p.resource_id == ^id)
    Repo.delete_all(from p in Page, where: p.resource_id == ^id)
    Enum.each(pages, &File.rm(Uploads.path(&1.storage_key)))
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

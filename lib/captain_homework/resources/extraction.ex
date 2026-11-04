defmodule CaptainHomework.Resources.Extraction do
  @moduledoc "Extracts independent illustrations while preserving the source image."
  import Ecto.Query
  alias CaptainHomework.{AI, ImageCrops, Repo, Uploads}
  alias CaptainHomework.Study.{Page, Resource}

  @max_count 10
  def max_count, do: @max_count

  def source(profile_id, lesson_id, page_id) do
    page =
      Repo.one(
        from p in Page,
          join: l in assoc(p, :lesson),
          where: p.id == ^page_id and p.lesson_id == ^lesson_id and l.profile_id == ^profile_id
      )

    with %Page{kind: "illustration", resource_id: resource_id, status: "ready"} <- page,
         true <- is_binary(resource_id),
         true <- page.content_type in ~w(image/jpeg image/png image/webp),
         %Resource{status: "ready", processing_stage: nil} <- Repo.get(Resource, resource_id) do
      {:ok, page}
    else
      _ ->
        {:error,
         "Cette illustration n’est plus disponible ou sa ressource est en cours de traitement."}
    end
  end

  def extract(profile_id, lesson_id, page_id, count, instructions)
      when is_integer(count) and count in 1..@max_count and is_binary(instructions) do
    with true <- String.length(instructions) <= 4000,
         {:ok, page} <- source(profile_id, lesson_id, page_id),
         {:ok, data, type} <- read_image(page),
         {:ok, regions} <- AI.extract_illustrations(data, type, count, String.trim(instructions)),
         :ok <- validate_regions(regions, count) do
      save_crops(profile_id, page, regions)
    else
      false -> {:error, "Les consignes sont trop longues (4 000 caractères maximum)."}
      {:error, _} = error -> error
      _ -> {:error, "L’extraction n’a pas abouti. Précise tes consignes puis réessaie."}
    end
  rescue
    _ -> {:error, "L’extraction a été interrompue. L’illustration originale est conservée."}
  end

  def extract(_, _, _, _, _),
    do: {:error, "Choisis entre 1 et #{@max_count} illustrations à extraire."}

  defp read_image(page) do
    with {:ok, %{type: :regular, size: size}} when size <= 12_000_000 <-
           File.stat(Uploads.path(page.storage_key)),
         {:ok, data} <- File.read(Uploads.path(page.storage_key)),
         {:ok, type, _} <- Uploads.image_type(data) do
      {:ok, data, type}
    else
      _ -> {:error, "L’illustration est illisible ou dépasse 12 Mo."}
    end
  end

  defp validate_regions(regions, count) when is_list(regions) and length(regions) == count do
    indexed = Enum.with_index(regions, 1)
    ids = Enum.map(indexed, fn {_, index} -> to_string(index) end)

    if Enum.all?(regions, &is_map/1) do
      regions =
        Enum.map(indexed, fn {region, index} ->
          region |> Map.take(~w(x y width height)) |> Map.put("image_id", to_string(index))
        end)

      bounds = Enum.map(regions, &Map.drop(&1, ["image_id"]))

      if Enum.uniq(bounds) == bounds and ImageCrops.validate(ids, regions) == :ok,
        do: :ok,
        else:
          {:error,
           "Les zones identifiées sont invalides ou identiques. Précise tes consignes puis réessaie."}
    else
      {:error, "Les zones identifiées sont illisibles. Réessaie l’extraction."}
    end
  end

  defp validate_regions(_, count),
    do:
      {:error,
       "L’extraction doit identifier exactement #{count} illustrations. Précise tes consignes."}

  defp save_crops(profile_id, page, regions) do
    crops = Enum.map(regions, &%{region: &1, key: Ecto.UUID.generate() <> ".png"})

    result =
      try do
        with :ok <- File.mkdir_p(Uploads.directory()),
             :ok <- render_crops(page, crops),
             {:ok, analyzed_crops} <- analyze_crops(crops) do
          Repo.transaction(fn ->
            case source(profile_id, page.lesson_id, page.id) do
              {:ok, current} when current.storage_key == page.storage_key ->
                last =
                  Repo.one(
                    from p in Page,
                      where: p.lesson_id == ^page.lesson_id and p.kind == "illustration",
                      select: max(p.position)
                  ) || -1

                resource = Repo.get!(Resource, page.resource_id)

                resource
                |> Ecto.Changeset.change(catalogue: nil, catalogue_hash: nil)
                |> Repo.update!()

                for {crop, index} <- Enum.with_index(analyzed_crops, 1) do
                  Repo.insert!(%Page{
                    lesson_id: page.lesson_id,
                    resource_id: page.resource_id,
                    extracted_from_id: page.id,
                    kind: "illustration",
                    status: "ready",
                    filename: Path.rootname(page.filename) <> "-extrait-#{index}.png",
                    storage_key: crop.key,
                    content_type: "image/png",
                    position: last + index,
                    text: crop.analysis["text"],
                    document_kind: crop.analysis["document_kind"]
                  })
                end

              _ ->
                Repo.rollback(
                  "La ressource a changé pendant l’extraction. Aucune illustration n’a été ajoutée."
                )
            end
          end)
        end
      rescue
        _ -> {:error, "Les illustrations n’ont pas pu être enregistrées. Réessaie."}
      end

    case result do
      {:ok, pages} ->
        Phoenix.PubSub.broadcast(
          CaptainHomework.PubSub,
          "lesson:#{page.lesson_id}",
          :lesson_updated
        )

        {:ok, pages}

      error ->
        Enum.each(crops, &File.rm(Uploads.path(&1.key)))

        case error do
          {:error, message} when is_binary(message) -> error
          _ -> {:error, "Les illustrations n’ont pas pu être enregistrées. Réessaie."}
        end
    end
  end

  defp analyze_crops(crops) do
    crops
    |> Task.async_stream(
      &analyze_crop/1,
      max_concurrency: 3,
      ordered: true,
      timeout: 180_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:ok, crop}}, {:ok, analyzed} ->
        {:cont, {:ok, analyzed ++ [crop]}}

      _, _ ->
        {:halt,
         {:error,
          "Le contenu d’une illustration n’a pas pu être reconnu. Réessaie l’extraction ; l’originale est conservée."}}
    end)
  end

  defp analyze_crop(crop) do
    with {:ok, data} <- File.read(Uploads.path(crop.key)),
         {:ok, %{"text" => text, "document_kind" => kind} = analysis}
         when is_binary(text) and kind in ~w(course assessment activity other) <-
           AI.analyze_resource(data, "image/png"),
         true <- String.trim(text) != "" do
      {:ok, Map.put(crop, :analysis, analysis)}
    else
      _ -> {:error, :unreadable}
    end
  rescue
    _ -> {:error, :unreadable}
  end

  defp render_crops(page, crops) do
    Enum.reduce_while(crops, :ok, fn crop, :ok ->
      with {:ok, data} <- ImageCrops.render(Uploads.path(page.storage_key), crop.region),
           :ok <- File.write(Uploads.path(crop.key), data) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end
end

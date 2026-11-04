defmodule CaptainHomework.AI.VisibleImages do
  @moduledoc "Prepares exactly the document regions visible to the student for the reviewer."
  alias CaptainHomework.{ImageCrops, Uploads}

  def prepare(questions, supports, pages) do
    sources = Map.new(pages, &{&1.id, &1})

    with {:ok, questions, images} <- prepare_nodes(questions, sources, %{}),
         {:ok, supports, images} <- prepare_nodes(supports, sources, images),
         :ok <- budget(images) do
      {:ok, questions, supports, images |> Map.values() |> Enum.sort_by(& &1.id)}
    end
  end

  defp prepare_nodes(nodes, sources, images) do
    Enum.reduce_while(nodes, {:ok, [], images}, fn node, {:ok, nodes, images} ->
      ids = Map.get(node, "image_ids", [])
      regions = Map.get(node, "image_regions", [])

      with :ok <- ImageCrops.validate(ids, regions),
           {:ok, visible_ids, images} <- prepare_images(ids, regions, sources, images) do
        visible = node |> Map.put("image_ids", visible_ids) |> Map.delete("image_regions")
        {:cont, {:ok, nodes ++ [visible], images}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp prepare_images(ids, regions, sources, images) do
    Enum.reduce_while(ids, {:ok, [], images}, fn source_id, {:ok, ids, images} ->
      region = Enum.find(regions, &(&1["image_id"] == source_id))
      id = visible_id(source_id, region)

      case Map.fetch(images, id) do
        {:ok, _} ->
          {:cont, {:ok, ids ++ [id], images}}

        :error ->
          case prepare_image(sources[source_id], region, id) do
            {:ok, image} ->
              images = Map.put(images, id, image)

              case budget(images) do
                :ok -> {:cont, {:ok, ids ++ [id], images}}
                error -> {:halt, error}
              end

            error ->
              {:halt, error}
          end
      end
    end)
  end

  defp budget(images) do
    unique = images |> Map.values() |> Enum.uniq_by(&:crypto.hash(:sha256, &1.data))
    bytes = Enum.reduce(unique, 0, &(byte_size(&1.data) + &2))

    if length(unique) <= 24 and bytes <= 24 * 1024 * 1024,
      do: :ok,
      else:
        {:error,
         "Les extraits du contrôle dépassent 24 images ou 24 Mo. Réduis le nombre de questions documentaires."}
  end

  defp visible_id(id, nil), do: id

  defp visible_id(id, region) do
    coordinates = Enum.map(~w(x y width height), &region[&1])

    hash =
      :crypto.hash(:sha256, :erlang.term_to_binary(coordinates)) |> Base.encode16(case: :lower)

    id <> "-crop-" <> binary_part(hash, 0, 16)
  end

  defp prepare_image(nil, _, _), do: {:error, "Image source indisponible pour le recadrage."}

  defp prepare_image(page, nil, _) do
    case File.read(Uploads.path(page.storage_key)) do
      {:ok, data} -> {:ok, Map.put(page, :data, data)}
      _ -> {:error, "Image source indisponible pour la vérification."}
    end
  end

  defp prepare_image(page, region, id) do
    with {:ok, data} <- ImageCrops.render(Uploads.path(page.storage_key), region) do
      {:ok,
       %{
         id: id,
         storage_key: id <> ".png",
         content_type: "image/png",
         data: data,
         resource_id: page.resource_id,
         kind: page.kind,
         filename: "extrait-#{page.filename}"
       }}
    end
  end
end

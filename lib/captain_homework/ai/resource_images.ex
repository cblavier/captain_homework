defmodule CaptainHomework.AI.ResourceImages do
  @moduledoc false
  alias CaptainHomework.Uploads

  @max_images 24
  @max_bytes 24 * 1024 * 1024

  # Cache once during catalogue selection; missing unused candidates are not fatal.
  def metadata(sources) do
    Map.new(Enum.uniq_by(sources, & &1.storage_key), fn page ->
      metadata =
        case File.read(Uploads.path(page.storage_key)) do
          {:ok, data} -> describe(data)
          _ -> nil
        end

      {page.storage_key, metadata}
    end)
  end

  def transmission_groups(sources) do
    info =
      Map.new(Enum.uniq_by(sources, & &1.storage_key), fn page ->
        data = File.read!(Uploads.path(page.storage_key))
        {page.storage_key, Map.put(describe(data), :data, data)}
      end)

    sources
    |> groups(info)
    |> Enum.map(&Map.put(&1, :data, info[&1.image.storage_key].data))
  end

  defp describe(data), do: %{size: byte_size(data), hash: :crypto.hash(:sha256, data)}

  def selection_required?(sources, examples) do
    match?({:error, _}, select(sources, examples, :all))
  end

  def select(sources, examples, selected_page_ids, info \\ nil) do
    info = info || metadata(sources ++ examples)

    with {:ok, mandatory, optional} <- candidates(sources, selected_page_ids, info) do
      cond do
        not available?(mandatory ++ examples, info) ->
          {:error,
           "Une image sélectionnée est indisponible. Réimporte la ressource avant de générer le contrôle."}

        not fits?(examples, info) ->
          {:error,
           "Les contrôles d’exemple dépassent 24 images ou 24 Mo. Réduis leur nombre dans l’onglet Contrôles."}

        not fits?(mandatory ++ examples, info) ->
          {:error,
           "Les pages sélectionnées et contrôles d’exemple dépassent 24 images ou 24 Mo. Réduis le nombre de pages ou d’exemples ; aucune page sélectionnée n’a été omise."}

        true ->
          selected =
            Enum.reduce(optional, mandatory, fn candidate, selected ->
              if available?([candidate], info) and
                   fits?(selected ++ [candidate] ++ examples, info),
                 do: selected ++ [candidate],
                 else: selected
            end)

          {:ok, selected, examples}
      end
    end
  end

  defp candidates(sources, :all, _info), do: {:ok, sources, []}

  defp candidates(sources, ids, info) when is_list(ids) do
    pages_by_id = sources |> Enum.filter(&(&1.kind == "resource")) |> Map.new(&{&1.id, &1})
    ids = Enum.uniq(ids)

    page_hashes =
      for page <- Map.values(pages_by_id),
          %{hash: hash} <- [info[page.storage_key]],
          into: MapSet.new(),
          do: {page.resource_id, hash}

    if Enum.all?(ids, &Map.has_key?(pages_by_id, &1)) do
      pages = Enum.map(ids, &Map.fetch!(pages_by_id, &1))

      illustrations =
        pages
        |> Enum.flat_map(fn page ->
          Enum.filter(
            sources,
            &(&1.kind == "illustration" and associated?(&1, page, info, page_hashes))
          )
        end)
        |> Enum.uniq_by(& &1.id)

      {:ok, pages, illustrations}
    else
      {:error,
       "Une page sélectionnée n’appartient pas aux ressources disponibles de cette leçon."}
    end
  end

  defp candidates(_, _, _),
    do: {:error, "La sélection doit contenir une liste d’identifiants de pages."}

  defp associated?(illustration, page, info, page_hashes) do
    if illustration.resource_id == page.resource_id and not is_nil(page.resource_id) do
      if page_copy?(illustration, info, page_hashes) do
        same_content?(illustration, page, info)
      else
        case {page_number(illustration.filename), page_number(page.filename)} do
          {nil, nil} -> false
          {number, number} -> true
          _ -> false
        end
      end
    else
      false
    end
  end

  # Web images and standalone uploads are stored as a page plus an identical
  # illustration. Their filenames may collide or resemble PDF page filenames.
  defp page_copy?(illustration, info, page_hashes) do
    case info[illustration.storage_key] do
      %{hash: hash} -> MapSet.member?(page_hashes, {illustration.resource_id, hash})
      _ -> false
    end
  end

  defp same_content?(illustration, page, info) do
    case {info[illustration.storage_key], info[page.storage_key]} do
      {%{hash: hash}, %{hash: hash}} -> true
      _ -> false
    end
  end

  defp page_number(filename) do
    case Regex.run(~r/^page-(\d+)(?:-|\.)/, filename || "") do
      [_, number] -> String.to_integer(number)
      _ -> nil
    end
  end

  defp available?(pages, info), do: Enum.all?(pages, &is_map(info[&1.storage_key]))

  defp groups(pages, info) do
    pages
    |> Enum.group_by(fn page ->
      case info[page.storage_key] do
        %{hash: hash} -> hash
        _ -> {:missing, page.storage_key}
      end
    end)
    |> Map.values()
    |> Enum.sort_by(fn same -> Enum.find_index(pages, &(&1.id == hd(same).id)) end)
    |> Enum.map(fn same ->
      preferred = Enum.find(same, &(&1.kind == "illustration")) || hd(same)
      %{image: preferred, ids: Enum.map(same, & &1.id)}
    end)
  end

  defp fits?(pages, info) do
    groups = groups(pages, info)

    length(groups) <= @max_images and
      Enum.reduce(groups, 0, &(info[&1.image.storage_key].size + &2)) <= @max_bytes
  end
end

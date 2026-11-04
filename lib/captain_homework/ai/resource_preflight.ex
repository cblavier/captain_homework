defmodule CaptainHomework.AI.ResourcePreflight do
  @moduledoc "Resolves mandatory question dependencies before a generation request is sent."

  alias CaptainHomework.AI.ResourceImages
  alias CaptainHomework.Exams.{BuildError, Illustrations}
  alias CaptainHomework.Uploads

  @doc """
  Reserves images referenced by retained questions and the previous plan before
  adding optional catalogue candidates. Required dependencies are never omitted
  to fit a request budget. Custom exclusions are represented by the allowed IDs
  in the catalogue context, independently of its smaller selection budget.
  """
  def prepare(lesson, content, selected, examples, kept, base \\ %{}, opts \\ []) do
    nodes = kept ++ List.wrap(base["questions"]) ++ List.wrap(base["supports"])

    with {:ok, context} <- decode_context(content),
         {:ok, required_ids} <- references(nodes, "image_ids"),
         {:ok, source_ids} <- references(nodes, "source_page_ids"),
         :ok <- valid_regions(nodes),
         :ok <- allowed_dependencies(context, required_ids, source_ids, selected, opts),
         {:ok, context} <- source_context(context, source_ids, lesson),
         :ok <- consistent_snapshot_sources(lesson, kept),
         available <- available_images(lesson, kept),
         :ok <- snapshot_regions(nodes, available),
         {:ok, mandatory} <- resolve_images(required_ids, available),
         :ok <- available_files(mandatory ++ examples),
         {:ok, _, _} <- within_budget(mandatory, examples) do
      images = mandatory |> add_optional(selected, examples) |> Enum.map(&with_content_hash/1)
      context = restrict_visible_catalogue(context, images)
      {:ok, Jason.encode!(context), images, examples}
    end
  end

  @doc """
  Returns lesson image sources, falling back to retained question snapshots when
  the original file no longer exists. Snapshot crops are marked so the caller
  can display already-cropped pixels without applying the crop a second time.
  """
  def available_images(lesson, questions) do
    sources = Illustrations.sources(lesson)

    snapshots =
      Enum.flat_map(questions, fn question ->
        for asset <- List.wrap(question["images"]),
            is_map(asset),
            is_binary(asset["source_page_id"]),
            asset["source_page_id"] in List.wrap(question["image_ids"]),
            is_binary(asset["storage_key"]),
            File.regular?(Uploads.path(asset["storage_key"])) do
          %{
            id: asset["source_page_id"],
            storage_key: asset["storage_key"],
            content_type: asset["content_type"] || "image/png",
            resource_id: "retained-question",
            kind: "illustration",
            filename: "illustration-conservee",
            extracted_from_id: nil,
            snapshot?: true,
            snapshot_crop: asset["crop"]
          }
        end
      end)

    readable = Enum.filter(sources, &readable?/1)
    unreadable = Enum.reject(sources, &readable?/1)

    (readable ++ snapshots ++ unreadable)
    |> Enum.uniq_by(& &1.id)
    |> Enum.map(&with_content_hash/1)
  end

  defp decode_context(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, %{"catalogue" => entries, "source_kinds" => kinds} = context}
      when is_list(entries) and is_map(kinds) ->
        {:ok, context}

      _ ->
        error(:invalid_contract, "Le contexte des ressources est invalide.")
    end
  end

  defp decode_context(_),
    do: error(:invalid_contract, "Le contexte des ressources est invalide.")

  defp references(nodes, field) do
    if Enum.all?(nodes, fn node ->
         is_map(node) and is_list(Map.get(node, field, [])) and
           Enum.all?(Map.get(node, field, []), &(is_binary(&1) and &1 != ""))
       end) do
      {:ok, nodes |> Enum.flat_map(&Map.get(&1, field, [])) |> Enum.uniq()}
    else
      error(:invalid_contract, "Une question contient des références de ressources invalides.")
    end
  end

  defp allowed_dependencies(context, image_ids, source_ids, selected, opts) do
    custom? =
      Keyword.get(
        opts,
        :custom_instructions?,
        String.trim(Keyword.get(opts, :instructions, "")) != ""
      )

    if custom? do
      entries = context["catalogue"]

      allowed_images =
        context["allowed_image_ids"] ||
          Enum.flat_map(entries, &List.wrap(&1["visual_page_ids"])) ++
            Enum.map(selected, & &1.id)

      allowed_sources =
        context["allowed_source_page_ids"] ||
          Map.keys(context["source_kinds"]) ++
            Enum.flat_map(entries, &List.wrap(&1["source_page_ids"]))

      excluded_images = image_ids -- allowed_images
      excluded_sources = source_ids -- allowed_sources

      if excluded_images == [] and excluded_sources == [] do
        :ok
      else
        error(
          :incompatible_constraints,
          "Une question conservée nécessite une ressource exclue par tes consignes. Modifie les consignes ou les questions à reprendre.",
          %{"image_ids" => excluded_images, "source_page_ids" => excluded_sources}
        )
      end
    else
      :ok
    end
  end

  defp valid_regions(nodes) do
    Enum.reduce_while(nodes, :ok, fn node, :ok ->
      case CaptainHomework.ImageCrops.validate(
             Map.get(node, "image_ids", []),
             Map.get(node, "image_regions", [])
           ) do
        :ok -> {:cont, :ok}
        {:error, message} -> {:halt, error(:invalid_contract, message)}
      end
    end)
  end

  defp source_context(context, source_ids, lesson) do
    pages = Map.new(Illustrations.content_pages(lesson), &{&1.id, &1})
    missing = Enum.reject(source_ids, &Map.has_key?(pages, &1))

    if missing == [] do
      kinds =
        Enum.reduce(source_ids, context["source_kinds"], fn id, kinds ->
          Map.put(kinds, id, if(pages[id].kind == "lesson", do: "lesson", else: "resource"))
        end)

      {:ok, Map.put(context, "source_kinds", kinds)}
    else
      error(
        :missing_source,
        "Une source nécessaire à une question conservée n’est plus disponible. Vérifie les leçons et les ressources avant de reprendre.",
        %{"source_page_ids" => missing}
      )
    end
  end

  defp resolve_images(ids, available) do
    by_id = Map.new(available, &{&1.id, &1})
    missing = Enum.reject(ids, &Map.has_key?(by_id, &1))

    if missing == [] do
      {:ok, Enum.map(ids, &Map.fetch!(by_id, &1))}
    else
      error(
        :missing_asset,
        "Une illustration obligatoire n’est plus disponible. Réimporte la ressource avant de reprendre le contrôle.",
        %{"image_ids" => missing}
      )
    end
  end

  defp snapshot_regions(nodes, available) do
    snapshots = available |> Enum.filter(&Map.get(&1, :snapshot?, false)) |> Map.new(&{&1.id, &1})

    conflicts =
      for node <- nodes,
          id <- Map.get(node, "image_ids", []),
          snapshot = snapshots[id],
          not is_nil(snapshot),
          region <- [Enum.find(List.wrap(node["image_regions"]), &(&1["image_id"] == id))],
          region != snapshot.snapshot_crop,
          do: id

    if conflicts == [] do
      :ok
    else
      error(
        :missing_asset,
        "Une illustration conservée ne couvre pas le cadrage demandé. Réimporte sa source avant de reprendre le contrôle.",
        %{"image_ids" => Enum.uniq(conflicts)}
      )
    end
  end

  defp consistent_snapshot_sources(lesson, questions) do
    sources = Map.new(Illustrations.sources(lesson), &{&1.id, &1})

    conflicts =
      for question <- questions,
          Map.has_key?(question, "images"),
          id <- Map.get(question, "image_ids", []),
          asset <- [Illustrations.snapshot_asset(question, id)],
          not retained_asset_consistent?(asset, sources[id]),
          do: id

    if conflicts == [] do
      :ok
    else
      error(
        :stale_dependency,
        "Une ressource a changé depuis la création d’une question conservée, ou sa version ne peut plus être vérifiée. Vérifie cette ressource avant de reprendre le contrôle.",
        %{"image_ids" => Enum.uniq(conflicts)}
      )
    end
  end

  defp retained_asset_consistent?(nil, _), do: false

  defp retained_asset_consistent?(asset, source) do
    if not is_nil(source) and readable?(source) do
      snapshot_matches_source?(asset, source)
    else
      if is_binary(asset["content_hash"]),
        do: saved_snapshot_matches?(asset, nil),
        else: true
    end
  end

  defp snapshot_matches_source?(nil, _), do: false

  defp snapshot_matches_source?(%{"source_content_hash" => expected} = asset, source)
       when is_binary(expected) do
    with {:ok, bytes} <- File.read(Uploads.path(source.storage_key)) do
      content_hash(bytes) == expected and saved_snapshot_matches?(asset, source)
    else
      _ -> false
    end
  end

  defp snapshot_matches_source?(asset, source) do
    current =
      case asset["crop"] do
        nil -> File.read(Uploads.path(source.storage_key))
        region -> CaptainHomework.ImageCrops.render(Uploads.path(source.storage_key), region)
      end

    with {:ok, current} <- current,
         {:ok, saved} <- File.read(Uploads.path(asset["storage_key"])) do
      content_hash(current) == content_hash(saved)
    else
      _ -> false
    end
  end

  defp saved_snapshot_matches?(%{"content_hash" => expected} = asset, _source)
       when is_binary(expected) do
    case File.read(Uploads.path(asset["storage_key"])) do
      {:ok, bytes} -> content_hash(bytes) == expected
      _ -> false
    end
  end

  defp saved_snapshot_matches?(asset, source),
    do: snapshot_matches_source?(Map.delete(asset, "source_content_hash"), source)

  defp available_files(images) do
    missing = images |> Enum.reject(&readable?/1) |> Enum.map(& &1.id)

    if missing == [],
      do: :ok,
      else:
        error(
          :missing_asset,
          "Le fichier d’une illustration obligatoire est indisponible. Réimporte la ressource avant de reprendre le contrôle.",
          %{"image_ids" => missing}
        )
  end

  defp readable?(image),
    do: is_binary(image.storage_key) and File.regular?(Uploads.path(image.storage_key))

  defp with_content_hash(image) do
    hash =
      case File.read(Uploads.path(image.storage_key)) do
        {:ok, bytes} -> content_hash(bytes)
        {:error, _} -> nil
      end

    Map.put(image, :content_hash, hash)
  end

  defp content_hash(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp within_budget(images, examples) do
    case ResourceImages.select(images, examples, :all) do
      {:ok, _, _} = result -> result
      {:error, message} -> error(:resource_budget, message)
    end
  end

  defp add_optional(mandatory, selected, examples) do
    metadata = ResourceImages.metadata(mandatory ++ selected ++ examples)

    Enum.reduce(selected, mandatory, fn image, images ->
      candidate = Enum.uniq_by(images ++ [image], & &1.id)

      case ResourceImages.select(candidate, examples, :all, metadata) do
        {:ok, _, _} -> candidate
        {:error, _} -> images
      end
    end)
  end

  defp restrict_visible_catalogue(context, images) do
    available = MapSet.new(images, & &1.id)

    Map.update!(context, "catalogue", fn entries ->
      Enum.filter(entries, fn entry ->
        Enum.all?(List.wrap(entry["visual_page_ids"]), &MapSet.member?(available, &1))
      end)
    end)
  end

  defp error(kind, message, details \\ %{}),
    do: {:error, BuildError.new(kind, :preflight, message, details: details, retryable?: false)}
end

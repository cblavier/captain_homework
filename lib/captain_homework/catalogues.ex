defmodule CaptainHomework.Catalogues do
  @moduledoc "Persistent, source-versioned pedagogical indexes."
  import Ecto.Query
  alias CaptainHomework.{AI, Repo}
  alias CaptainHomework.Study.{Page, Resource}
  alias CaptainHomework.Exams.Illustrations
  alias CaptainHomework.AI.ResourceImages

  @version 1

  def prepare_resource(resource), do: prepare(Resource, resource.id)

  def prepare_page(%{resource_id: id}) when not is_nil(id), do: prepare(Resource, id)
  def prepare_page(%{kind: "lesson", id: id}), do: prepare(Page, id)
  def prepare_page(_), do: {:ok, %{"entries" => []}}

  def schedule(page) do
    if AI.catalogue_supported?() do
      Task.Supervisor.start_child(CaptainHomework.Tasks, fn -> prepare_page(page) end)
    end

    :ok
  end

  defp prepare(module, id) do
    if AI.catalogue_supported?() do
      # Serialize callers without holding a database transaction during an API request.
      :global.trans({{__MODULE__, module, id}, self()}, fn ->
        with source when not is_nil(source) <- Repo.get(module, id),
             pages when pages != [] <- source_pages(source),
             true <- Enum.all?(pages, &(&1.status == "ready" and String.trim(&1.text) != "")) do
          hash = fingerprint(pages)

          if is_map(source.catalogue) and
               source.catalogue_hash in [hash, fingerprint(pages, true)] do
            if source.catalogue_hash != hash do
              source |> Ecto.Changeset.change(catalogue_hash: hash) |> Repo.update!()
            end

            {:ok, source.catalogue}
          else
            CaptainHomework.ProcessingProgress.update(source, 90, "Analyse pédagogique")

            try do
              with {:ok, catalogue} <- AI.build_catalogue(pages),
                   :ok <- validate(catalogue, pages),
                   current when not is_nil(current) <- Repo.get(module, id),
                   true <- fingerprint(source_pages(current)) == hash,
                   {:ok, _} <-
                     current
                     |> Ecto.Changeset.change(catalogue: catalogue, catalogue_hash: hash)
                     |> Repo.update() do
                if source.status == "ready" do
                  CaptainHomework.ProcessingProgress.complete(source)
                end

                {:ok, catalogue}
              else
                {:error, reason} ->
                  {:error, reason}

                _ ->
                  {:error,
                   "Le document a changé pendant sa préparation. Relance la création du contrôle."}
              end
            after
              if source.status == "ready", do: CaptainHomework.ProcessingProgress.clear(source)
            end
          end
        else
          _ -> {:error, "Termine la lecture des pages avant de préparer leurs exercices."}
        end
      end)
    else
      {:ok, %{"entries" => []}}
    end
  rescue
    _ ->
      {:error,
       "La préparation du catalogue a été interrompue. Le texte reconnu est conservé ; réessaie."}
  end

  defp source_pages(%Resource{id: id}),
    do:
      Repo.all(
        from p in Page,
          where: p.resource_id == ^id and p.kind == "resource",
          order_by: [p.position, p.id]
      )

  defp source_pages(%Page{} = page), do: [page]

  defp fingerprint(pages, include_position? \\ false) do
    {@version, AI.provider(), Application.get_env(:captain_homework, :openai_model),
     Enum.map(
       pages,
       fn page ->
         fields = [:id, :text, :filename, :storage_key, :document_kind, :content_type]

         fields =
           if page.kind == "lesson" and not include_position?,
             do: fields,
             else: [:position | fields]

         Map.take(page, fields)
       end
     )}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def validate(%{"entries" => entries}, pages)
      when is_list(entries) and length(entries) in 1..160 do
    ids = MapSet.new(pages, & &1.id)

    visual_ids =
      pages
      |> Enum.filter(&(&1.kind == "resource" and String.starts_with?(&1.content_type, "image/")))
      |> MapSet.new(& &1.id)

    valid? =
      Enum.all?(entries, fn entry ->
        is_map(entry) and entry["kind"] in ["knowledge", "exercise"] and
          is_binary(entry["title"]) and byte_size(entry["title"]) in 1..500 and
          is_binary(entry["content"]) and byte_size(entry["content"]) in 1..8000 and
          is_list(entry["keywords"]) and Enum.all?(entry["keywords"], &is_binary/1) and
          is_boolean(entry["usable"]) and
          valid_ids?(entry["source_page_ids"], ids, false) and
          valid_ids?(entry["visual_page_ids"], visual_ids, true)
      end)

    if valid?,
      do: :ok,
      else:
        {:error,
         "Le catalogue pédagogique contient des références invalides. Relance sa préparation."}
  end

  def validate(_, _),
    do: {:error, "Le catalogue pédagogique est incomplet. Relance sa préparation."}

  defp valid_ids?(values, ids, empty?) do
    is_list(values) and (empty? or values != []) and length(values) <= 8 and
      Enum.all?(values, &MapSet.member?(ids, &1))
  end

  def context(lesson, pages, examples, count, instructions, retries) do
    sources =
      pages
      |> Enum.map(&if(&1.resource_id, do: {Resource, &1.resource_id}, else: {Page, &1.id}))
      |> Enum.uniq()

    with {:ok, entries} <- collect(sources) do
      select(entries, lesson, examples, count, instructions, retries)
    end
  end

  defp collect(sources) do
    Enum.reduce_while(sources, {:ok, []}, fn {module, id}, {:ok, entries} ->
      case prepare(module, id) do
        {:ok, catalogue} -> {:cont, {:ok, entries ++ catalogue["entries"]}}
        error -> {:halt, error}
      end
    end)
  end

  defp select(entries, lesson, examples, count, instructions, retries) do
    images = Illustrations.sources(lesson)
    visual_ids = MapSet.new(images, & &1.id)
    image_metadata = ResourceImages.metadata(images ++ examples)
    query = words(lesson.title <> " " <> instructions)
    used = words(Enum.map_join(retries, " ", & &1["prompt"]))
    seed = length(Map.get(lesson, :exams, []))

    ranked =
      entries
      |> Enum.filter(& &1["usable"])
      |> Enum.sort_by(fn entry ->
        terms = words(entry["title"] <> " " <> Enum.join(entry["keywords"], " "))

        score =
          MapSet.size(MapSet.intersection(query, terms)) * 4 -
            MapSet.size(MapSet.intersection(used, terms)) * 2

        priority = if entry["kind"] == "exercise", do: 1, else: 0
        {-priority, -score, :erlang.phash2({entry, seed})}
      end)

    knowledge = Enum.filter(ranked, &(&1["kind"] == "knowledge"))

    # Select each exercise together with its supporting facts as an indivisible bundle.
    bundles =
      ranked
      |> Enum.filter(&(&1["kind"] == "exercise"))
      |> Enum.map(fn exercise ->
        supports =
          Enum.filter(knowledge, fn fact ->
            Enum.any?(fact["source_page_ids"], &(&1 in exercise["source_page_ids"]))
          end)

        [exercise | supports]
      end)

    lesson_ids = lesson.pages |> Enum.filter(&(&1.kind == "lesson")) |> MapSet.new(& &1.id)

    {course_bundles, resource_bundles} =
      (bundles ++ Enum.map(knowledge, &[&1]))
      |> Enum.split_with(fn bundle ->
        Enum.any?(bundle, fn entry ->
          Enum.any?(entry["source_page_ids"], &MapSet.member?(lesson_ids, &1))
        end)
      end)

    # Reserve the best feasible visual exercise, then keep relevance order. Rejected
    # candidates do not consume the number of exercises we may still select.
    {visual, _} =
      Enum.split_with(resource_bundles, fn bundle ->
        Enum.any?(bundle, &(&1["kind"] == "exercise" and &1["visual_page_ids"] != []))
      end)

    first_visual =
      Enum.find(visual, fn bundle ->
        ids = bundle |> Enum.flat_map(& &1["visual_page_ids"]) |> Enum.uniq()

        byte_size(Jason.encode!(bundle)) <= 40_000 and length(ids) <= 8 and
          match?({:ok, _, _}, ResourceImages.select(images, examples, ids, image_metadata))
      end)

    bundles =
      if first_visual do
        remaining = Enum.reject(resource_bundles, &(&1 == first_visual))
        [first_visual | interleave(course_bundles, remaining)]
      else
        interleave(course_bundles, resource_bundles)
      end

    {selected, page_ids, _} =
      Enum.reduce(bundles, {[], [], 0}, fn bundle, {selected, page_ids, bytes} = acc ->
        added = Enum.reject(bundle, &(&1 in selected))
        required_ids = Enum.flat_map(added, & &1["visual_page_ids"])
        next_ids = Enum.uniq(page_ids ++ required_ids)
        size = byte_size(Jason.encode!(added))

        exercises = Enum.count(selected ++ added, &(&1["kind"] == "exercise"))

        if added != [] and exercises <= min(count * 2, 40) and bytes + size <= 40_000 and
             length(next_ids) <= 8 and
             Enum.all?(required_ids, &MapSet.member?(visual_ids, &1)) do
          case ResourceImages.select(images, examples, next_ids, image_metadata) do
            {:ok, _, _} -> {selected ++ added, next_ids, bytes + size}
            _ -> acc
          end
        else
          acc
        end
      end)

    if selected == [] do
      {:error,
       "Aucun exercice autonome disponible dans le catalogue. Vérifie les documents et leurs supports."}
    else
      with {:ok, images, examples} <-
             ResourceImages.select(images, examples, page_ids, image_metadata) do
        source_kinds =
          selected
          |> Enum.flat_map(& &1["source_page_ids"])
          |> Enum.uniq()
          |> Map.new(fn id ->
            {id, if(MapSet.member?(lesson_ids, id), do: "lesson", else: "resource")}
          end)

        {:ok, Jason.encode!(%{"catalogue" => selected, "source_kinds" => source_kinds}), images,
         examples}
      end
    end
  end

  defp interleave([], right), do: right
  defp interleave(left, []), do: left

  defp interleave([left | rest_left], [right | rest_right]),
    do: [left, right | interleave(rest_left, rest_right)]

  defp words(text),
    do:
      text
      |> String.downcase()
      |> String.normalize(:nfd)
      |> String.replace(~r/\p{Mn}/u, "")
      |> String.split(~r/[^a-z0-9]+/u, trim: true)
      |> Enum.filter(&(String.length(&1) >= 4))
      |> MapSet.new()
end

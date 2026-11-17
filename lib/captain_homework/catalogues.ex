defmodule CaptainHomework.Catalogues do
  @moduledoc "Persistent, source-versioned pedagogical indexes."
  import Ecto.Query
  alias CaptainHomework.{AI, Repo}
  alias CaptainHomework.Study.{Page, Resource}
  alias CaptainHomework.Exams.Illustrations
  alias CaptainHomework.AI.ResourceImages

  @version 2
  @visual_support_version 3

  # Old saved plans may have excluded every imported image before selection.
  # Refresh those contexts once, including the author's exclusions, on repair.
  def current_context?(content, lesson) do
    case Jason.decode(content) do
      {:ok, %{"visual_support_version" => version}} -> version == @visual_support_version
      _ -> MapSet.size(image_resource_ids(lesson.resources)) == 0
    end
  end

  def prepare_resource(resource), do: prepare(Resource, resource.id)

  def prepare_page(%{resource_id: id}) when not is_nil(id), do: prepare(Resource, id)
  def prepare_page(%{parent_page_id: id}) when not is_nil(id), do: prepare(Page, id)
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
             true <- Enum.all?(pages, &(&1.status == "ready")) do
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
                   "Le document a changé pendant sa préparation. Relance la création de l’évaluation."}
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
          where:
            p.resource_id == ^id and not p.legacy_hidden and p.association_status == "linked",
          order_by: [p.source_page_number, p.position, p.id]
      )

  defp source_pages(%Page{} = page),
    do: [
      page
      | Repo.all(
          from p in Page,
            where: p.parent_page_id == ^page.id and not p.legacy_hidden,
            order_by: [p.position, p.id]
        )
    ]

  defp fingerprint(pages, include_position? \\ false) do
    {@version, AI.provider(), Application.get_env(:captain_homework, :openai_model),
     Enum.map(
       pages,
       fn page ->
         fields = [
           :id,
           :title,
           :parent_page_id,
           :text,
           :filename,
           :storage_key,
           :document_kind,
           :content_type,
           :ocr_status
         ]

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
      |> Enum.filter(
        &((&1.kind == "lesson" or Illustrations.resource_content_page?(&1)) and
            String.starts_with?(&1.content_type, "image/"))
      )
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

  def context(lesson, pages, examples, count, instructions, retries, opts \\ []) do
    instructions = CaptainHomework.Exams.Instructions.custom(instructions)

    sources =
      pages
      |> Enum.map(
        &if(&1.resource_id,
          do: {Resource, &1.resource_id},
          else: {Page, &1.parent_page_id || &1.id}
        )
      )
      |> Enum.uniq()

    with {:ok, entries} <- collect(sources),
         entries <- include_visual_supports(entries, pages, lesson.resources),
         {:ok, entries, use_examples?} <- select_requested_content(entries, pages, instructions) do
      select(entries, lesson, examples, count, instructions, retries, use_examples?, opts)
    end
  end

  # Imported images and cropped figures remain visual supports even when a cached
  # catalogue only describes them as text. Use the imported image's content page,
  # not its duplicate illustration, so source IDs and transmitted pixels agree.
  defp include_visual_supports(entries, pages, resources) do
    image_resources = image_resource_ids(resources)

    indexed =
      entries
      |> Enum.filter(& &1["usable"])
      |> Enum.flat_map(& &1["visual_page_ids"])
      |> MapSet.new()

    figures =
      for page <- pages,
          Illustrations.extracted?(page) or
            (page.kind == "resource" and MapSet.member?(image_resources, page.resource_id)),
          page.status == "ready",
          String.starts_with?(page.content_type, "image/"),
          not MapSet.member?(indexed, page.id) do
        %{
          "kind" => "visual",
          "title" => page.filename,
          "content" =>
            "Support visuel à associer aux connaissances du cours, sans exercice imposé.\n" <>
              page.text,
          "keywords" => [],
          "usable" => true,
          "source_page_ids" => [page.id],
          "visual_page_ids" => [page.id]
        }
      end

    entries ++ figures
  end

  defp image_resource_ids(resources) do
    resources
    |> Enum.filter(
      &(&1.status == "ready" and String.starts_with?(&1.content_type || "", "image/"))
    )
    |> MapSet.new(& &1.id)
  end

  defp select_requested_content(entries, pages, instructions) do
    provider = AI.provider()

    if String.trim(instructions) != "" and
         function_exported?(provider, :select_exam_content, 3) do
      provider.select_exam_content(entries, pages, instructions)
    else
      {:ok, entries, true}
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

  defp select(entries, lesson, examples, count, instructions, retries, use_examples?, opts) do
    examples = if use_examples?, do: examples, else: []
    images = Illustrations.sources(lesson)
    visual_ids = MapSet.new(images, & &1.id)
    image_metadata = ResourceImages.metadata(images ++ examples)
    query = words(lesson.title <> " " <> instructions)
    used = words(Enum.map_join(retries, " ", & &1["prompt"]))
    seed = length(Map.get(lesson, :exams, []))
    preferred_sources = MapSet.new(Keyword.get(opts, :preferred_source_ids, []))

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
      (bundles ++
         Enum.map(knowledge, &[&1]) ++
         Enum.map(Enum.filter(ranked, &(&1["kind"] == "visual")), &[&1]))
      |> Enum.split_with(fn bundle ->
        Enum.any?(bundle, fn entry ->
          Enum.any?(entry["source_page_ids"], &MapSet.member?(lesson_ids, &1))
        end)
      end)

    # Reserve visual dependencies before optional resource text consumes the budget.
    # Only author-authorized entries reach this point, including during repairs.
    {visual, text} =
      Enum.split_with(resource_bundles, fn bundle ->
        Enum.any?(bundle, &(&1["kind"] in ["exercise", "visual"] and &1["visual_page_ids"] != []))
      end)

    {preferred_visual, other_visual} =
      Enum.split_with(visual, fn bundle ->
        Enum.any?(bundle, fn entry ->
          Enum.any?(entry["source_page_ids"], &MapSet.member?(preferred_sources, &1))
        end)
      end)

    bundles = preferred_visual ++ other_visual ++ interleave(course_bundles, text)

    {selected, page_ids, _} =
      Enum.reduce(bundles, {[], [], 0}, fn bundle, {selected, page_ids, bytes} = acc ->
        added = Enum.reject(bundle, &(&1 in selected))
        required_ids = Enum.flat_map(added, & &1["visual_page_ids"])
        next_ids = Enum.uniq(page_ids ++ required_ids)
        size = byte_size(Jason.encode!(added))

        exercises = Enum.count(selected ++ added, &(&1["kind"] == "exercise"))

        course? =
          Enum.any?(bundle, fn entry ->
            Enum.any?(entry["source_page_ids"], &MapSet.member?(lesson_ids, &1))
          end)

        resource_size = if course?, do: 0, else: size

        if added != [] and (course? or exercises <= count) and
             bytes + resource_size <= resource_budget(count) and length(next_ids) <= 8 and
             Enum.all?(required_ids, &MapSet.member?(visual_ids, &1)) do
          case ResourceImages.select(images, examples, next_ids, image_metadata,
                 include_figures: false
               ) do
            {:ok, _, _} -> {selected ++ added, next_ids, bytes + resource_size}
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
             ResourceImages.select(images, examples, page_ids, image_metadata,
               include_figures: false
             ) do
        source_kinds =
          selected
          |> Enum.flat_map(& &1["source_page_ids"])
          |> Enum.uniq()
          |> Map.new(fn id ->
            {id, if(MapSet.member?(lesson_ids, id), do: "lesson", else: "resource")}
          end)

        {:ok,
         Jason.encode!(%{
           "visual_support_version" => @visual_support_version,
           "image_selection" => %{
             "preferred_source_ids" => Enum.sort(preferred_sources),
             "authorized_image_ids" =>
               ranked |> Enum.flat_map(& &1["visual_page_ids"]) |> Enum.uniq(),
             "selected_image_ids" => Enum.map(images, & &1.id),
             "resource_budget_bytes" => resource_budget(count)
           },
           "catalogue" => selected,
           "source_kinds" => source_kinds,
           "lesson_page_numbers" => CaptainHomework.Exams.LessonPages.numbers(lesson.pages),
           "allowed_image_ids" => ranked |> Enum.flat_map(& &1["visual_page_ids"]) |> Enum.uniq(),
           "allowed_source_page_ids" =>
             ranked |> Enum.flat_map(& &1["source_page_ids"]) |> Enum.uniq(),
           "use_examples" => use_examples?
         }), images, examples}
      end
    end
  end

  # A context budget, not a quota of questions or documents. Course entries are
  # always retained; resource exercises keep all their dependent facts together.
  defp resource_budget(count), do: max(8_000, min(count * 1_200, 24_000))

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

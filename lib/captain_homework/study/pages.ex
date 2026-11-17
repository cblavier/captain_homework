defmodule CaptainHomework.Study.Pages do
  @moduledoc "Chapter pages and their directly attached illustrations. IDs never depend on names or order."
  import Ecto.Query
  alias CaptainHomework.{Repo, Study, Uploads}
  alias CaptainHomework.Study.{Page, Resource}

  def originals(lesson, kind),
    do: Enum.filter(lesson.pages, &(&1.kind == kind and not &1.legacy_hidden))

  def illustrations(lesson, page),
    do:
      Enum.filter(
        lesson.pages,
        &(&1.parent_page_id == page.id and &1.kind == "illustration" and not &1.legacy_hidden)
      )

  def suggest_name(page, title)
      when is_binary(title) and page.kind in ["lesson", "resource", "illustration"] do
    title = title |> String.replace(~r/\s+/u, " ") |> String.trim() |> String.slice(0, 60)
    resource = if page.resource_id, do: Repo.get(Resource, page.resource_id)
    defaults = [Path.rootname(page.filename || "Page")]

    defaults =
      if resource,
        do:
          defaults ++
            [
              resource.title,
              "#{resource.title || Path.rootname(resource.filename)} — page #{page.source_page_number}"
            ],
        else: defaults

    default_illustration? =
      page.kind == "illustration" and Regex.match?(~r/^Illustration \d+$/, page.title || "")

    if title != "" and (page.title in defaults or default_illustration?) do
      from(p in Study.Page, where: p.id == ^page.id and p.title == ^page.title)
      |> Repo.update_all(set: [title: title])
    end

    :ok
  end

  def suggest_name(_, _), do: :ok

  def suggested_name(title, fallback) when is_binary(title) do
    case title |> String.replace(~r/\s+/u, " ") |> String.trim() |> String.slice(0, 60) do
      "" -> fallback
      name -> name
    end
  end

  def suggested_name(_, fallback), do: fallback

  def name(page), do: page.title || page.filename || "Page"

  def available?(page) do
    page.status == "ready" and page.processing_stage == nil and
      (is_nil(page.resource_id) or
         match?(
           %Resource{status: "ready", processing_stage: nil},
           Repo.get(Resource, page.resource_id)
         ))
  end

  def change_name(page, attrs) do
    page
    |> Ecto.Changeset.cast(attrs, [:title])
    |> Ecto.Changeset.update_change(:title, &String.trim(&1 || ""))
    |> Ecto.Changeset.validate_required([:title])
    |> Ecto.Changeset.validate_length(:title, max: 240)
  end

  def rename(profile_id, lesson_id, id, attrs) do
    page = Study.get_page!(profile_id, id)

    if page.lesson_id == lesson_id do
      with {:ok, page} <- page |> change_name(attrs) |> Repo.update() do
        invalidate(page)
        {:ok, page}
      end
    else
      {:error, :not_found}
    end
  end

  def attach(profile_id, lesson_id, illustration_id, parent_id) do
    illustration = Study.get_page!(profile_id, illustration_id)
    parent = Study.get_page!(profile_id, parent_id)

    if illustration.lesson_id == lesson_id and parent.lesson_id == lesson_id and
         illustration.kind == "illustration" and illustration.association_status == "unresolved" and
         parent.kind in ["lesson", "resource"] and is_nil(parent.parent_page_id) do
      result =
        Repo.transaction(fn ->
          last =
            Repo.one(
              from p in Page, where: p.parent_page_id == ^parent.id, select: max(p.position)
            ) || -1

          updated =
            illustration
            |> Ecto.Changeset.change(
              parent_page_id: parent.id,
              resource_id: parent.resource_id,
              association_status: "linked",
              position: last + 1
            )
            |> Repo.update!()

          invalidate(parent)

          old_import =
            if illustration.resource_id && illustration.resource_id != parent.resource_id &&
                 not Repo.exists?(
                   from p in Page, where: p.resource_id == ^illustration.resource_id
                 ),
               do: Repo.get!(Resource, illustration.resource_id) |> Repo.delete!()

          {updated, old_import}
        end)

      case result do
        {:ok, {updated, old_import}} ->
          if old_import, do: cleanup(old_import.storage_key)
          {:ok, updated}

        error ->
          error
      end
    else
      {:error, :invalid_parent}
    end
  end

  def invalidate(page) do
    root_id = page.parent_page_id || page.id

    from(p in Page, where: p.id == ^root_id)
    |> Repo.update_all(set: [catalogue: nil, catalogue_hash: nil])

    if page.resource_id do
      from(r in Resource, where: r.id == ^page.resource_id)
      |> Repo.update_all(set: [catalogue: nil, catalogue_hash: nil])
    end

    :ok
  end

  def delete(page) do
    result =
      Repo.transaction(fn ->
        current = Repo.get!(Page, page.id)

        if current.resource_id do
          resource = Repo.get!(Resource, current.resource_id)

          if resource.status == "processing" or resource.processing_stage != nil,
            do: Repo.rollback("Attends la fin du traitement avant de supprimer cette page.")
        end

        children = Repo.all(from p in Page, where: p.parent_page_id == ^page.id)
        invalidate(current)
        Enum.each(children, &Repo.delete!/1)
        Repo.delete!(current)

        if current.resource_id &&
             not Repo.exists?(from p in Page, where: p.resource_id == ^current.resource_id) do
          resource = Repo.get!(Resource, current.resource_id)
          Repo.delete!(resource)
          {current, [resource | children] ++ [current]}
        else
          {current, children ++ [current]}
        end
      end)

    case result do
      {:ok, {deleted, files}} ->
        Enum.each(files, &cleanup(&1.storage_key))
        {:ok, deleted}

      error ->
        error
    end
  end

  defp cleanup(nil), do: :ok

  defp cleanup(key) do
    if not Repo.exists?(from p in Page, where: p.storage_key == ^key) and
         not Repo.exists?(from r in Resource, where: r.storage_key == ^key),
       do: File.rm(Uploads.path(key))
  end
end

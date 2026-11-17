defmodule CaptainHomework.Repo.Migrations.UnifyLearningPages do
  use Ecto.Migration

  def up do
    alter table(:pages) do
      add :title, :string
      add :legacy_kind, :string
      add :parent_page_id, references(:pages, type: :binary_id, on_delete: :delete_all)
      add :source_page_number, :integer
      add :extraction_origin, :string
      add :association_status, :string, default: "linked", null: false
      add :legacy_hidden, :boolean, default: false, null: false
      add :ocr_status, :string, default: "pending", null: false
    end

    alter table(:resources) do
      add :category, :string, default: "resource", null: false
    end

    create index(:pages, [:parent_page_id, :position])
    flush()

    columns = ~w(id resource_id kind filename extracted_from_id text status content_type position)
    pages = repo().query!("SELECT #{Enum.join(columns, ",")} FROM pages").rows
    pages = Enum.map(pages, &Map.new(Enum.zip(columns, &1)))

    web_ids =
      repo().query!("SELECT id FROM resources WHERE content_type='text/html'").rows
      |> List.flatten()
      |> MapSet.new()

    web_roots =
      pages
      |> Enum.filter(
        &(&1["kind"] == "resource" and &1["content_type"] == "text/plain" and
            MapSet.member?(web_ids, &1["resource_id"]))
      )
      |> Map.new(&{&1["resource_id"], &1})

    by_id = Map.new(pages, &{&1["id"], &1})

    Enum.each(pages, fn page ->
      roots =
        Enum.filter(
          pages,
          &(&1["resource_id"] == page["resource_id"] and &1["kind"] == "resource")
        )

      original_parent = parent(page, roots, by_id, MapSet.new())
      web_root = web_roots[page["resource_id"]]

      web_image? =
        web_root && page["kind"] == "resource" &&
          String.starts_with?(page["content_type"] || "", "image/")

      kind = if web_image?, do: "illustration", else: page["kind"]
      root = if web_root && kind == "illustration", do: web_root, else: original_parent
      number = page_number(page["filename"])

      duplicate? =
        page["kind"] == "illustration" && original_parent &&
          page["filename"] == original_parent["filename"] &&
          is_nil(page["extracted_from_id"])

      origin =
        if kind == "illustration",
          do: if(page["extracted_from_id"], do: "manual", else: "automatic")

      ocr =
        if page["status"] == "ready" and
             (page["kind"] != "illustration" or page["text"] not in [nil, ""]),
           do: "complete",
           else: "pending"

      status =
        if kind == "illustration" and is_nil(root), do: "unresolved", else: "linked"

      title =
        if kind == "illustration",
          do: "Illustration #{(page["position"] || 0) + 1}",
          else: Path.rootname(page["filename"] || "Page")

      repo().query!(
        "UPDATE pages SET kind=?, legacy_kind=?, title=?, parent_page_id=?, source_page_number=?, extraction_origin=?, association_status=?, legacy_hidden=?, ocr_status=? WHERE id=?",
        [
          kind,
          if(web_image?, do: page["kind"]),
          title,
          root && root["id"],
          number,
          origin,
          status,
          if(duplicate?, do: 1, else: 0),
          ocr,
          page["id"]
        ]
      )
    end)
  end

  defp parent(%{"kind" => kind}, _, _, _) when kind != "illustration", do: nil

  defp parent(page, roots, by_id, seen) do
    if MapSet.member?(seen, page["id"]) do
      nil
    else
      source = by_id[page["extracted_from_id"]]

      candidates =
        Enum.filter(roots, fn root ->
          root["filename"] == page["filename"] or
            (page_number(page["filename"]) != nil and
               page_number(root["filename"]) == page_number(page["filename"]))
        end)

      cond do
        source && source["kind"] in ["lesson", "resource"] -> source
        source -> parent(source, roots, by_id, MapSet.put(seen, page["id"]))
        length(candidates) == 1 -> hd(candidates)
        length(roots) == 1 -> hd(roots)
        true -> nil
      end
    end
  end

  defp page_number(name) do
    case Regex.run(~r/^page-(\d+)(?:-|\.)/, name || "") do
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  def down do
    execute "UPDATE pages SET kind=legacy_kind WHERE legacy_kind IS NOT NULL"
    flush()
    drop index(:pages, [:parent_page_id, :position])

    alter table(:pages) do
      remove :title
      remove :legacy_kind
      remove :parent_page_id
      remove :source_page_number
      remove :extraction_origin
      remove :association_status
      remove :legacy_hidden
      remove :ocr_status
    end

    alter table(:resources), do: remove(:category)
  end
end

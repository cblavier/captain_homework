defmodule Mix.Tasks.LearningPages.BackfillOcr do
  use Mix.Task
  @shortdoc "Reports missing illustration OCR; --apply processes it resumably"
  @moduledoc """
  Lists missing illustration OCR and unresolved legacy associations without calling AI.
  Use `mix learning_pages.backfill_ocr --apply` to OCR linked illustrations only.
  `--limit N` limits a batch (default 20). Completed OCR is never overwritten.
  """
  import Ecto.Query
  alias CaptainHomework.{AI, Repo, Study, Uploads}

  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [apply: :boolean, limit: :integer])
    Mix.Task.run("app.start")

    missing =
      Repo.all(
        from p in Study.Page,
          where: p.kind == "illustration" and p.ocr_status != "complete" and not p.legacy_hidden,
          order_by: [p.inserted_at, p.id]
      )

    unresolved =
      Repo.all(
        from p in Study.Page,
          where:
            p.kind == "illustration" and p.association_status == "unresolved" and
              not p.legacy_hidden
      )

    Mix.shell().info(
      "#{length(missing)} illustration(s) sans OCR, #{length(unresolved)} association(s) à vérifier."
    )

    for page <- unresolved, do: Mix.shell().info("Association à vérifier : #{page.id}")

    if opts[:apply] do
      missing
      |> Enum.reject(&is_nil(&1.parent_page_id))
      |> Enum.take(max(opts[:limit] || 20, 0))
      |> Enum.each(fn page ->
        case AI.analyze_resource(Uploads.read(page), page.content_type) do
          {:ok, %{"text" => text}} ->
            {updated, _} =
              Repo.update_all(
                from(p in Study.Page, where: p.id == ^page.id and p.ocr_status != "complete"),
                set: [text: text, ocr_status: "complete", status: "ready", error: nil]
              )

            if updated == 1, do: Study.Pages.invalidate(page)
            Mix.shell().info("OCR terminé : #{page.id}")

          {:error, _} ->
            Mix.shell().error("OCR à reprendre : #{page.id}")
        end
      end)
    end
  end
end

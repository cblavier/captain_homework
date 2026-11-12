defmodule CaptainHomework.Resources.Naming do
  @moduledoc false
  alias CaptainHomework.Uploads
  alias CaptainHomework.Resources.{Audio, Documents, Download, GoogleDrive}

  def title(resource) do
    resource.title || remote_title(resource) || Documents.title(resource) ||
      filename_title(resource.filename)
  end

  def filename_title(name) do
    name |> Path.basename() |> Path.rootname() |> clean()
  end

  def html_title(html) do
    document = LazyHTML.from_document(html)

    title =
      document
      |> LazyHTML.query("meta[property='og:title']")
      |> LazyHTML.attribute("content")
      |> List.first()

    clean(title) ||
      document |> LazyHTML.query("title") |> LazyHTML.text() |> clean()
  rescue
    _ -> nil
  end

  defp remote_title(%{content_type: "text/html"} = resource) do
    resource |> Uploads.read() |> html_title()
  end

  defp remote_title(resource) do
    uri = URI.parse(resource.source_url)

    if match?({:ok, _, _}, Audio.youtube_url(uri)) or
         match?({:ok, _, _}, GoogleDrive.prepare(uri)) do
      case Download.fetch_page(resource.source_url) do
        {:ok, body, type, _} when type in ["text/html", "application/xhtml+xml"] ->
          body
          |> html_title()
          |> strip_service()

        _ ->
          nil
      end
    end
  end

  defp strip_service(nil), do: nil

  defp strip_service(title) do
    title
    |> String.replace(~r/\s*[-–|]\s*(YouTube|Google Drive)\s*$/i, "")
    |> String.replace(~r/\.(pdf|mp3|mp4|docx?|pptx?|xlsx?|png|jpe?g|webp)$/i, "")
    |> clean()
  end

  defp clean(nil), do: nil

  defp clean(text) do
    case text |> String.replace(~r/\s+/u, " ") |> String.trim() |> String.slice(0, 240) do
      "" -> nil
      title -> title
    end
  end
end

defmodule CaptainHomework.Resources.GoogleDrive do
  @moduledoc false
  @download "https://drive.usercontent.google.com/download"
  @access_error "Ce fichier Google Drive n’est pas téléchargeable publiquement. Active « Tous les utilisateurs disposant du lien » avec le téléchargement autorisé, ou importe directement le PDF."

  def prepare(%URI{host: host} = uri) do
    if String.downcase(host || "") in ["drive.google.com", "drive.usercontent.google.com"] do
      query = URI.decode_query(uri.query || "")

      id =
        case Regex.run(
               ~r{^/file/d/([A-Za-z0-9_-]+)(?:/(?:view|preview|edit))?/?$},
               uri.path || ""
             ) do
          [_, id] -> id
          _ -> if uri.path in ["/open", "/uc", "/download"], do: query["id"]
        end

      if is_binary(id) and Regex.match?(~r/^[A-Za-z0-9_-]{10,200}$/, id) do
        params = %{"id" => id, "export" => "download", "confirm" => "t"}

        params =
          if query["resourcekey"],
            do: Map.put(params, "resourcekey", query["resourcekey"]),
            else: params

        {:ok, @download <> "?" <> URI.encode_query(params), id}
      else
        {:error,
         "Utilise le lien de partage d’un fichier Google Drive, et non celui d’un dossier."}
      end
    else
      :not_drive
    end
  end

  def confirmation(body, id) when byte_size(body) <= 1_000_000 do
    document = LazyHTML.from_document(body)
    form = LazyHTML.query(document, "form#download-form")
    action = form |> LazyHTML.attribute("action") |> List.first()

    fields =
      Map.new(["id", "export", "confirm", "uuid", "resourcekey"], fn name ->
        value =
          form
          |> LazyHTML.query("input[type=hidden][name=#{name}]")
          |> LazyHTML.attribute("value")
          |> List.first()

        {name, value}
      end)

    if action == @download and fields["id"] == id and fields["export"] == "download" and
         is_binary(fields["confirm"]) and byte_size(fields["confirm"]) in 1..200 do
      params = fields |> Enum.reject(fn {_, value} -> is_nil(value) end) |> Map.new()
      {:ok, @download <> "?" <> URI.encode_query(params)}
    else
      {:error, @access_error}
    end
  rescue
    _ -> {:error, @access_error}
  end

  def confirmation(_, _), do: {:error, @access_error}
  def access_error, do: {:error, @access_error}
end

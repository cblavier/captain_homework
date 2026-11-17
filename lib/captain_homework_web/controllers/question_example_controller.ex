defmodule CaptainHomeworkWeb.QuestionExampleController do
  use CaptainHomeworkWeb, :controller
  alias CaptainHomework.{QuestionDefinitions, Uploads}

  def show(conn, %{"type_id" => type_id, "id" => id}) do
    type = QuestionDefinitions.get!(type_id)
    assets = (type.example["images"] || []) ++ List.wrap(type.example["audio"])
    asset = Enum.find(assets, &(is_map(&1) and &1["id"] == id))

    if asset && is_binary(asset["storage_key"]) &&
         File.regular?(Uploads.path(asset["storage_key"])) do
      conn
      |> put_resp_content_type(asset["content_type"])
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_file(200, Uploads.path(asset["storage_key"]))
    else
      send_resp(conn, 404, "Support d’exemple introuvable")
    end
  end
end

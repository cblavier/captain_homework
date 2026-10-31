defmodule CaptainHomeworkWeb.ResourceController do
  use CaptainHomeworkWeb, :controller
  alias CaptainHomework.{Resources, Uploads}

  def show(conn, %{"child" => child, "id" => id}) do
    profile = CaptainHomeworkWeb.ProfilePath.find(child)
    if is_nil(profile), do: raise(Ecto.NoResultsError, queryable: CaptainHomework.Study.Profile)
    resource = Resources.get!(profile.id, id)

    if resource.storage_key && File.regular?(Uploads.path(resource.storage_key)) do
      conn
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_download({:file, Uploads.path(resource.storage_key)},
        filename: resource.filename,
        content_type: resource.content_type
      )
    else
      send_resp(conn, 404, "Document indisponible")
    end
  end
end

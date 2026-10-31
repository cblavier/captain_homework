defmodule CaptainHomeworkWeb.PageController do
  use CaptainHomeworkWeb, :controller
  alias CaptainHomework.{Study, Uploads}

  def show(conn, %{"id" => id} = params) do
    profile =
      if params["child"] do
        CaptainHomeworkWeb.ProfilePath.find(params["child"])
      else
        Study.get_profile(get_session(conn, :profile_id)) || List.first(Study.profiles())
      end

    if profile do
      page = Study.get_page!(profile.id, id)

      conn
      |> put_resp_content_type(page.content_type)
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_file(200, Uploads.path(page.storage_key))
    else
      send_resp(conn, 404, "Page introuvable")
    end
  end
end

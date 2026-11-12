defmodule CaptainHomeworkWeb.SharedAccess do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _) do
    conn =
      if get_session(conn, :shared_visitor),
        do: conn,
        else: put_session(conn, :shared_visitor, CaptainHomework.ExamShares.token())

    conn
    |> assign_metadata()
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
  end

  defp assign_metadata(%{path_info: ["partage", token]} = conn) do
    case CaptainHomework.ExamShares.fetch(token) do
      {:ok, share} ->
        assign(conn, :share_metadata, CaptainHomeworkWeb.SharedExamMetadata.build(share))

      _ ->
        conn
    end
  end

  defp assign_metadata(conn), do: conn
end

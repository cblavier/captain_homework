defmodule CaptainHomeworkWeb.SharedAccess do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _) do
    conn =
      if get_session(conn, :shared_visitor),
        do: conn,
        else: put_session(conn, :shared_visitor, CaptainHomework.ExamShares.token())

    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
  end
end

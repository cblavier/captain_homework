defmodule CaptainHomeworkWeb.Access do
  import Plug.Conn
  import Phoenix.Controller
  def init(action), do: action

  def call(conn, :require_access) do
    if allowed?(get_session(conn)), do: conn, else: conn |> redirect(to: "/connexion") |> halt()
  end

  def allowed?(session) do
    password = Application.get_env(:captain_homework, :access_password)
    password in [nil, ""] or session["access"] == digest(password)
  end

  def digest(password), do: :crypto.hash(:sha256, password) |> Base.encode64()

  def on_mount(:ensure_access, _params, session, socket) do
    if allowed?(session),
      do: {:cont, socket},
      else: {:halt, Phoenix.LiveView.redirect(socket, to: "/connexion")}
  end
end

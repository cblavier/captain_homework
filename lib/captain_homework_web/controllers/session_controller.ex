defmodule CaptainHomeworkWeb.SessionController do
  use CaptainHomeworkWeb, :controller
  alias CaptainHomeworkWeb.Access
  def health(conn, _), do: json(conn, %{status: "ok"})

  def profile(conn, %{"profile_id" => id}) do
    case CaptainHomework.Study.get_profile(id) do
      nil ->
        conn |> put_status(:not_found) |> text("Profil introuvable")

      profile ->
        conn
        |> put_session(:profile_id, id)
        |> redirect(to: CaptainHomeworkWeb.ProfilePath.child_path(profile, "/"))
    end
  end

  def login(conn, _), do: render(conn, :login, error: nil)

  def authenticate(conn, %{"password" => supplied}) do
    expected = Application.get_env(:captain_homework, :access_password) || ""

    if expected == "" or
         Plug.Crypto.secure_compare(Access.digest(expected), Access.digest(supplied)) do
      conn
      |> configure_session(renew: true)
      |> put_session(:access, Access.digest(expected))
      |> redirect(to: "/")
    else
      conn |> put_status(:unauthorized) |> render(:login, error: "Mot de passe incorrect.")
    end
  end

  def logout(conn, _), do: conn |> clear_session() |> redirect(to: "/connexion")
end

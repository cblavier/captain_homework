defmodule CaptainHomeworkWeb.SessionController do
  use CaptainHomeworkWeb, :controller
  import CaptainHomework.Text
  alias CaptainHomework.{Accounts, Auth, Study}

  def health(conn, _), do: json(conn, %{status: "ok"})

  def profile(conn, %{"profile_id" => id}) do
    profile = Study.get_profile(id)

    if Accounts.profile_allowed?(conn.assigns.account, profile) do
      conn
      |> put_session(:profile_id, id)
      |> redirect(to: CaptainHomeworkWeb.ProfilePath.child_path(profile, "/"))
    else
      conn |> put_status(:not_found) |> text("Profil introuvable")
    end
  end

  def login(conn, _) do
    if Auth.valid?(get_session(conn)), do: redirect(conn, to: "/"), else: page(conn, nil)
  end

  def authenticate(conn, params) do
    account = params["account"]
    remember = params["remember"] == "true"
    conn = assign(conn, :selected_account, account) |> assign(:remember, remember)

    case Auth.attempt(account, params["pin"]) do
      :ok ->
        revoke(conn)
        Plug.CSRFProtection.delete_csrf_token()
        conn = conn |> configure_session(renew: true) |> clear_session()

        conn =
          put_session(
            conn,
            "live_socket_id",
            "auth:" <> Base.url_encode64(:crypto.strong_rand_bytes(24))
          )

        conn =
          Enum.reduce(Auth.session(account, remember), conn, fn {key, value}, conn ->
            put_session(conn, key, value)
          end)

        profile = Accounts.get(account) |> Accounts.profiles() |> List.first()
        conn = if profile, do: put_session(conn, :profile_id, profile.id), else: conn
        redirect(conn, to: CaptainHomeworkWeb.ProfilePath.child_path(profile, "/"))

      {:wait, seconds} ->
        blocked(conn, seconds)

      {:invalid, seconds} when seconds > 0 ->
        blocked(conn, seconds)

      {:invalid, _} ->
        conn |> put_status(:unauthorized) |> page("Code PIN incorrect.")

      :unconfigured ->
        conn
        |> put_status(:unauthorized)
        |> page("Ce compte est indisponible. Vérifiez sa configuration.")
    end
  end

  def logout(conn, _) do
    revoke(conn)

    conn
    |> clear_session()
    |> configure_session(drop: true)
    |> put_resp_header("cache-control", "private, no-store")
    |> redirect(to: "/connexion")
  end

  defp revoke(conn) do
    Auth.revoke(get_session(conn))

    if socket_id = get_session(conn, "live_socket_id"),
      do: CaptainHomeworkWeb.Endpoint.broadcast(socket_id, "disconnect", %{})
  end

  defp blocked(conn, seconds) do
    conn
    |> put_status(429)
    |> put_resp_header("retry-after", to_string(seconds))
    |> page(
      "Veuillez attendre #{count_label(seconds, "seconde", "secondes")} avant une nouvelle tentative."
    )
  end

  defp page(conn, error) do
    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> render(:login,
      error: error,
      configured: Auth.configured?(),
      accounts: Accounts.all(),
      selected_account: conn.assigns[:selected_account],
      remember: conn.assigns[:remember] || false
    )
  end
end

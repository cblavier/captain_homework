defmodule CaptainHomeworkWeb.Access do
  import Plug.Conn
  import Phoenix.Controller
  import Phoenix.LiveView, only: [attach_hook: 4, connected?: 1]
  alias CaptainHomework.{Accounts, Auth}

  def init(action), do: action
  def allowed?(session), do: Auth.valid?(session)

  def call(conn, :require_access) do
    conn = put_resp_header(conn, "cache-control", "private, no-store")
    session = get_session(conn)

    if allowed?(session) do
      account = Accounts.get(session["auth_account"])
      profiles = Accounts.profiles(account)
      profile = Enum.find(profiles, &(&1.id == session["profile_id"])) || List.first(profiles)
      conn = assign(conn, :account, account) |> assign(:profile, profile)

      if route_allowed?(account, conn.path_params) and
           settings_allowed?(account, conn.request_path) do
        conn
      else
        conn |> send_resp(404, "Profil introuvable") |> halt()
      end
    else
      conn |> configure_session(ignore: true) |> redirect(to: "/connexion") |> halt()
    end
  end

  def route_allowed?(account, %{"child" => child}),
    do: Accounts.profile_allowed?(account, CaptainHomeworkWeb.ProfilePath.find(child))

  def route_allowed?(_, _), do: true

  def on_mount(:ensure_access, params, session, socket) do
    account = Accounts.get(session["auth_account"])

    if allowed?(session) and route_allowed?(account, params) and
         settings_view_allowed?(account, socket) do
      if connected?(socket),
        do:
          Process.send_after(
            self(),
            :auth_expired,
            max(Auth.expires_at(session) - Auth.now(), 0) * 1000
          )

      socket =
        socket
        |> Phoenix.Component.assign(:account, account)
        |> attach_hook(:auth_event, :handle_event, fn event, _, socket ->
          if event == "save_subjects" and not Accounts.parent?(account),
            do: deny(socket),
            else: check(session, socket)
        end)
        |> attach_hook(:auth_params, :handle_params, fn params, _, socket ->
          if route_allowed?(account, params) and settings_view_allowed?(account, socket),
            do: check(session, socket),
            else: deny(socket)
        end)
        |> attach_hook(:auth_info, :handle_info, fn
          :auth_expired, socket -> deny(socket)
          _, socket -> check(session, socket)
        end)

      {:cont, socket}
    else
      deny(socket)
    end
  end

  defp settings_allowed?(account, path) do
    Accounts.parent?(account) or
      not Regex.match?(
        ~r{/(?:matieres/parametres|parametres/(?:matieres|types)(?:/.*)?)$},
        URI.decode(path)
      )
  end

  defp settings_view_allowed?(account, socket) do
    Accounts.parent?(account) or
      (socket.view != CaptainHomeworkWeb.QuestionTypesLive and
         socket.assigns.live_action not in [:subjects_settings, :subject_preferences])
  end

  defp check(session, socket), do: if(allowed?(session), do: {:cont, socket}, else: deny(socket))
  defp deny(socket), do: {:halt, Phoenix.LiveView.redirect(socket, to: "/connexion")}
end

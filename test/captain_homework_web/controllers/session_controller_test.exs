defmodule CaptainHomeworkWeb.SessionControllerTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Accounts, Auth, Repo}
  @moduletag :unauthenticated

  test "login has all five accounts, keypad and remember option", %{conn: conn} do
    doc = conn |> get("/connexion") |> html_response(200) |> LazyHTML.from_document()
    assert length(LazyHTML.query(doc, "#pin-form input[name=account]") |> LazyHTML.to_tree()) == 5
    assert length(LazyHTML.query(doc, "#pin-form [data-pin-digit]") |> LazyHTML.to_tree()) == 10

    assert length(LazyHTML.query(doc, "#pin-form input[name=remember]") |> LazyHTML.to_tree()) ==
             1
  end

  test "private routes reject unauthenticated visitors", %{conn: conn} do
    assert redirected_to(get(conn, "/alice")) == "/connexion"
    assert redirected_to(get(conn, "/alice/pages/unknown")) == "/connexion"
    refute Auth.valid?(%{"access" => "legacy"})
  end

  test "each configured account signs in with its PIN", %{conn: conn} do
    for account <- Accounts.all() do
      response = post(conn, "/connexion", %{account: account.id, pin: Accounts.pin(account.id)})
      assert response.status == 302
      session = get_session(response)
      assert session["auth_account"] == account.id
      assert Auth.valid?(session)
      assert_in_delta session["auth_expires_at"] - Auth.now(), 3600, 2
    end
  end

  test "remembered sessions expire and revoked cookies cannot be reused", %{conn: conn} do
    signed = post(conn, "/connexion", %{account: "family", pin: "12345678", remember: "true"})
    session = get_session(signed)
    assert_in_delta session["auth_expires_at"] - Auth.now(), 30 * 24 * 3600, 2
    assert redirected_to(delete(recycle(signed), "/session")) == "/connexion"
    refute Auth.valid?(session)
    assert redirected_to(get(recycle(signed), "/alice")) == "/connexion"
    fresh = Auth.session()
    Repo.update_all(Auth.Session, set: [expires_at: Auth.now() - 1])
    refute Auth.valid?(fresh)
  end

  test "child access is scoped across pages, profile switch and live navigation", %{conn: conn} do
    alice = profile()
    marius = profile("Marius")
    page(lesson(alice))
    other = page(lesson(marius))
    conn = conn |> post("/connexion", %{account: "child-1", pin: "23456789"}) |> recycle()
    {:ok, view, _} = live(conn, "/alice")
    refute has_element?(view, "#switch-profile-#{marius.id}")
    assert has_element?(view, "#logout")
    assert get(conn, "/marius").status == 404
    assert get(conn, "/marius/pages/#{other.id}").status == 404
    assert get(conn, "/marius/ressources/#{Ecto.UUID.generate()}").status == 404

    for kind <- ["images", "audio"] do
      assert get(conn, "/marius/controles/#{Ecto.UUID.generate()}/#{kind}/unknown").status == 404
    end

    assert post(conn, "/profil", %{profile_id: marius.id}).status == 404
    assert_error_sent 404, fn -> get(conn, "/pages/#{other.id}") end

    assert {:error, {:redirect, %{to: "/connexion"}}} =
             live(conn |> init_test_session(%{"auth_account" => "child-2"}), "/alice")
  end

  test "child does not receive another child's generation notifications", %{conn: conn} do
    other = exam(lesson(profile("Marius")))
    conn = conn |> post("/connexion", %{account: "child-1", pin: "23456789"}) |> recycle()
    {:ok, view, _} = live(conn, "/alice")
    send(view.pid, {:exam_generation_finished, other})
    refute has_element?(view, "#flash-info")
  end

  test "live navigation and events recheck authorization", %{conn: conn} do
    signed = post(conn, "/connexion", %{account: "child-1", pin: "23456789"})
    session = get_session(signed)
    {:ok, view, _} = live(recycle(signed), "/alice")
    render_patch(view, "/marius")
    assert_redirect(view, "/connexion")

    {:ok, view, _} = live(recycle(signed), "/alice")
    Auth.revoke(session)
    render_click(view, "open_modal", %{"modal" => "lesson"})
    assert_redirect(view, "/connexion")
  end

  test "parent and family accounts can switch between children", %{conn: conn} do
    marius = profile("Marius")

    for id <- ["family", "parent-1", "parent-2"] do
      signed = conn |> post("/connexion", %{account: id, pin: Accounts.pin(id)}) |> recycle()
      {:ok, view, _} = live(signed, "/alice")
      assert has_element?(view, "#switch-profile-#{marius.id}")
      assert redirected_to(post(signed, "/profil", %{profile_id: marius.id})) == "/marius"
    end
  end

  test "invalid PIN is rejected and the third failure is throttled", %{conn: conn} do
    id = "parent-2"
    assert Auth.attempt(id, Accounts.pin(id)) == :ok
    on_exit(fn -> :sys.replace_state(Auth, &Map.delete(&1, id)) end)

    for _ <- 1..2 do
      assert post(conn, "/connexion", %{account: id, pin: "bad"}).status == 401
    end

    response = post(conn, "/connexion", %{account: id, pin: "bad"})
    assert response.status == 429
    assert get_resp_header(response, "retry-after") == ["60"]
    assert post(conn, "/connexion", %{account: id, pin: Accounts.pin(id)}).status == 429
  end

  test "unconfigured application stays closed and changing PIN invalidates sessions", %{
    conn: conn
  } do
    original = Application.fetch_env!(:captain_homework, :accounts)
    on_exit(fn -> Application.put_env(:captain_homework, :accounts, original) end)
    session = Auth.session()

    Application.put_env(
      :captain_homework,
      :accounts,
      Enum.map(original, &Map.put(&1, :pin, "87654321"))
    )

    refute Auth.valid?(session)
    Application.put_env(:captain_homework, :accounts, [])
    refute Auth.valid?(session)
    doc = conn |> get("/connexion") |> html_response(200) |> LazyHTML.from_document()
    assert length(LazyHTML.query(doc, "#login-error") |> LazyHTML.to_tree()) == 1
    assert length(LazyHTML.query(doc, "#pin-form") |> LazyHTML.to_tree()) == 0
    assert redirected_to(get(conn, "/")) == "/connexion"
  end
end

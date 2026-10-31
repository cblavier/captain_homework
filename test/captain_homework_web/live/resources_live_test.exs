defmodule CaptainHomeworkWeb.ResourcesLiveTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Study, Resources, Repo, Uploads}

  setup do
    old = Application.fetch_env!(:captain_homework, :ai_provider)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.ResourceUIAI)
    on_exit(fn -> Application.put_env(:captain_homework, :ai_provider, old) end)
    :ok
  end

  test "resource upload exposes OCR and original illustrations", %{conn: conn} do
    l = lesson(profile())
    Phoenix.PubSub.subscribe(CaptainHomework.PubSub, "lesson:#{l.id}")
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}?onglet=ressources")

    image =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aLioAAAAASUVORK5CYII="
      )

    upload =
      file_input(view, "#upload-resources", :resources, [
        %{name: "activite.png", content: image, type: "image/png"}
      ])

    render_upload(upload, "activite.png")
    view |> form("#upload-resources") |> render_submit()
    assert_receive :lesson_updated, 2000
    assert_receive :lesson_updated, 2000
    send(view.pid, :lesson_updated)
    [resource] = Study.get_lesson!(l.profile_id, l.id).resources
    on_exit(fn -> File.rm(Uploads.path(resource.storage_key)) end)
    assert resource.status == "ready"
    assert has_element?(view, "#resource-#{resource.id}", "Exercices prioritaires")
    assert has_element?(view, "#resource-#{resource.id} .resource-text", "Observe le schéma.")

    [illustration] =
      Study.get_lesson!(l.profile_id, l.id).pages |> Enum.filter(&(&1.kind == "illustration"))

    assert File.read!(Uploads.path(illustration.storage_key)) == image
    original = get(conn, "/alice/ressources/#{resource.id}")
    assert response(original, 200) == image
    assert get_resp_header(original, "content-disposition") != []
    assert_error_sent 404, fn -> get(conn, "/marius/ressources/#{resource.id}") end
    view |> element("#delete-resource-#{resource.id}") |> render_click()
    refute has_element?(view, "#resource-#{resource.id}")
    refute File.exists?(Uploads.path(illustration.storage_key))
    assert Study.get_lesson!(l.profile_id, l.id).pages == []
  end

  test "URL form rejects private targets without importing", %{conn: conn} do
    l = lesson(profile())
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}?onglet=ressources")

    view
    |> form("#resource-url-form", resource: %{url: "http://127.0.0.1/admin"})
    |> render_submit()

    assert Study.get_lesson!(l.profile_id, l.id).resources == []
    assert has_element?(view, "[role=alert]", "URL publique")
  end

  test "a failed resource is displayed with a retry action", %{conn: conn} do
    l = lesson(profile())
    {:ok, resource} = Resources.create_url(l.profile_id, l.id, "https://example.com/doc.pdf")

    resource
    |> Ecto.Changeset.change(status: "error", error: "Document inaccessible")
    |> Repo.update!()

    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}?onglet=ressources")
    assert has_element?(view, "#resource-#{resource.id} [role=alert]", "Document inaccessible")
    assert has_element?(view, "#retry-resource-#{resource.id}")
  end
end

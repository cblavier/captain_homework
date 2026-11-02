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

  defp await_ready_resource(lesson) do
    case Study.get_lesson!(lesson.profile_id, lesson.id).resources do
      [%{status: "ready"}] ->
        :ok

      [%{status: "error", error: error}] ->
        flunk(error)

      _ ->
        assert_receive :lesson_updated, 2000
        await_ready_resource(lesson)
    end
  end

  test "processing progress survives navigation and updates live", %{conn: conn} do
    l = lesson(profile())
    {:ok, resource} = Resources.create_url(l.profile_id, l.id, "https://example.com/course.pdf")
    CaptainHomework.ProcessingProgress.update(resource, 58, "Lecture OCR — 2/4 pages")
    path = "/alice/lecons/#{l.id}?onglet=ressources"
    {:ok, view, _} = live(conn, path)
    selector = "#resource-progress-#{resource.id}"
    assert has_element?(view, selector <> " .spinner")
    assert has_element?(view, selector <> " strong", "≈ 58 %")
    assert has_element?(view, selector, "Lecture OCR — 2/4 pages")
    CaptainHomework.ProcessingProgress.update(resource, 90, "Analyse pédagogique")
    assert has_element?(view, selector, "Analyse pédagogique")
    {:ok, refreshed, _} = live(conn, path)
    assert has_element?(refreshed, selector <> " strong", "≈ 90 %")
    assert has_element?(refreshed, selector, "Analyse pédagogique")
  end

  test "course pages expose their analysis progress", %{conn: conn} do
    l = lesson(profile())
    course = page(l)
    CaptainHomework.ProcessingProgress.update(course, 90, "Analyse pédagogique")
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}?onglet=cours")
    selector = "#page-progress-#{course.id}"
    assert has_element?(view, selector <> " .spinner")
    assert has_element?(view, selector, "≈ 90 %")
    assert has_element?(view, selector, "Analyse pédagogique")
    CaptainHomework.ProcessingProgress.complete(course)
    refute has_element?(view, selector)
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

    assert has_element?(view, "#upload-resources input[data-phx-auto-upload]")
    render_upload(upload, "activite.png")
    view |> form("#upload-resources") |> render_submit()
    await_ready_resource(l)
    send(view.pid, :lesson_updated)
    [resource] = Study.get_lesson!(l.profile_id, l.id).resources
    on_exit(fn -> File.rm(Uploads.path(resource.storage_key)) end)
    assert resource.status == "ready"
    refute has_element?(view, "#resource-#{resource.id}", "Exercices prioritaires")
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
    view |> element("#open-resource-url") |> render_click()

    view
    |> form("#resource-url-form", resource: %{url: "http://127.0.0.1/admin"})
    |> render_submit()

    assert Study.get_lesson!(l.profile_id, l.id).resources == []

    assert has_element?(
             view,
             "#resource-url-modal #resource-url-error[role=alert]",
             "URL publique"
           )

    assert has_element?(view, "#resource-url[value='http://127.0.0.1/admin'][aria-invalid=true]")
  end

  test "URL import opens from the link below the upload and can be cancelled", %{conn: conn} do
    l = lesson(profile())
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}?onglet=ressources")

    assert has_element?(
             view,
             "#upload-resources #open-resource-url[type=button][aria-haspopup=dialog]"
           )

    refute has_element?(view, "#resource-url-form")

    view |> element("#open-resource-url") |> render_click()
    assert has_element?(view, "#resource-url-modal[role=dialog] #resource-url-form")

    view
    |> form("#resource-url-form", resource: %{url: "https://example.com/fiche.pdf"})
    |> render_change()

    view |> element("#cancel-resource-url") |> render_click()
    refute has_element?(view, "#resource-url-modal")
    assert Study.get_lesson!(l.profile_id, l.id).resources == []

    view |> element("#open-resource-url") |> render_click()
    assert has_element?(view, "#resource-url[value='']")
  end

  test "a successful URL import closes the modal and shows the resource", %{conn: conn} do
    defaults = Req.default_options()
    Req.default_options(Keyword.put(defaults, :plug, {Req.Test, __MODULE__}))
    Req.Test.set_req_test_to_shared()
    on_exit(fn -> Req.default_options(defaults) end)

    image =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aLioAAAAASUVORK5CYII="
      )

    Req.Test.stub(__MODULE__, fn conn ->
      conn |> put_resp_content_type("image/png") |> send_resp(200, image)
    end)

    l = lesson(profile())
    Phoenix.PubSub.subscribe(CaptainHomework.PubSub, "lesson:#{l.id}")
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}?onglet=ressources")
    view |> element("#open-resource-url") |> render_click()

    view
    |> form("#resource-url-form", resource: %{url: "https://8.8.8.8/activite.png"})
    |> render_submit()

    refute has_element?(view, "#resource-url-modal")

    await_ready_resource(l)
    send(view.pid, :lesson_updated)
    [resource] = Study.get_lesson!(l.profile_id, l.id).resources
    assert resource.status == "ready"
    assert has_element?(view, "#resource-#{resource.id}")
    assert File.read!(Uploads.path(resource.storage_key)) == image
    Resources.delete(l.profile_id, resource.id)
  end

  test "resource upload accepts a file larger than twenty megabytes", %{conn: conn} do
    l = lesson(profile())
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}?onglet=ressources")
    content = "%PDF-1.4\n" <> :binary.copy(" ", 21 * 1024 * 1024)

    upload =
      file_input(view, "#upload-resources", :resources, [
        %{name: "grand.pdf", content: content, type: "application/pdf"}
      ])

    assert {:ok, _} = preflight_upload(upload)
    assert has_element?(view, "#upload-resources .upload-entry", "grand.pdf")
    refute has_element?(view, "#upload-resources .error")
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

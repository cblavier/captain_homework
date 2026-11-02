defmodule CaptainHomeworkWeb.LessonCreationLiveTest do
  use CaptainHomeworkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures

  alias CaptainHomework.{Study, Uploads}

  setup %{conn: conn} do
    child = profile()
    {:ok, view, _} = live(conn, "/alice/matieres/francais")
    view |> element("#new-lesson") |> render_click()
    %{view: view, child: child}
  end

  test "keeps the lesson title while uploading and removing photos, then saves it", %{
    view: view,
    child: child
  } do
    old_key = Application.get_env(:captain_homework, :openai_api_key)
    Application.put_env(:captain_homework, :openai_api_key, nil)
    on_exit(fn -> Application.put_env(:captain_homework, :openai_api_key, old_key) end)

    title = "Le présent de l’indicatif"
    view |> form("#lesson-form", %{lesson: %{title: title}}) |> render_change()

    image =
      Base.decode64!(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aLioAAAAASUVORK5CYII="
      )

    first_upload =
      file_input(view, "#lesson-form", :pages, [
        %{name: "page-1.png", content: image, type: "image/png"}
      ])

    second_upload =
      file_input(view, "#lesson-form", :pages, [
        %{name: "page-2.png", content: image, type: "image/png"}
      ])

    render_upload(first_upload, "page-1.png", 50)
    assert has_element?(view, "#lesson-form #lesson-title[value='#{title}']")
    render_upload(first_upload, "page-1.png", 50)
    render_upload(second_upload, "page-2.png")
    assert has_element?(view, "#lesson-form #lesson-title[value='#{title}']")
    assert has_element?(view, "#lesson-form .upload-entry", "page-1.png")
    assert has_element?(view, "#lesson-form .upload-entry", "page-2.png")

    view
    |> element("#lesson-form .upload-entry:first-of-type button[phx-click=cancel_upload]")
    |> render_click()

    assert has_element?(view, "#lesson-form #lesson-title[value='#{title}']")
    refute has_element?(view, "#lesson-form .upload-entry", "page-1.png")
    assert has_element?(view, "#lesson-form .upload-entry", "page-2.png")
    view |> form("#lesson-form") |> render_submit()

    [lesson] = Study.lessons(child.id, "francais")
    [page] = lesson.pages
    on_exit(fn -> File.rm(Uploads.path(page.storage_key)) end)
    assert lesson.title == title
    assert page.filename == "page-2.png"
    assert File.read!(Uploads.path(page.storage_key)) == image
    assert_redirect(view, "/alice/lecons/#{lesson.id}")
  end

  test "keeps the submitted title when creation is rejected", %{view: view, child: child} do
    title = String.duplicate("a", 121)
    view |> form("#lesson-form", %{lesson: %{title: title}}) |> render_submit()

    assert has_element?(view, "#lesson-form [role=alert]")
    assert has_element?(view, "#lesson-form #lesson-title[value='#{title}']")
    assert Study.lessons(child.id, "francais") == []
  end

  test "starts with a blank title when reopening the creation form", %{view: view} do
    view |> form("#lesson-form", %{lesson: %{title: "Brouillon"}}) |> render_change()
    assert has_element?(view, "#lesson-title[value='Brouillon']")
    view |> element("#modal button[aria-label=Fermer]") |> render_click()
    view |> element("#new-lesson") |> render_click()
    assert has_element?(view, "#lesson-title[value='']")
  end
end

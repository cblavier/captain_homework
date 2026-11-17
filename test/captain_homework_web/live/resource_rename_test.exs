defmodule CaptainHomeworkWeb.ResourceRenameTest do
  use CaptainHomeworkWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Repo, Resources, Study}

  setup do
    lesson = lesson(profile())

    resource =
      Repo.insert!(%Study.Resource{lesson_id: lesson.id, filename: "cours.pdf", status: "ready"})

    {:ok, page} =
      Study.add_page(lesson, %{
        resource_id: resource.id,
        kind: "resource",
        filename: "page-1.png",
        storage_key: "test.png",
        content_type: "image/png",
        status: "ready"
      })

    %{lesson: lesson, resource: resource, page: page}
  end

  test "rename persists the display name and preserves the original filename", %{
    conn: conn,
    lesson: lesson,
    page: page
  } do
    path = "/alice/lecons/#{lesson.id}?onglet=ressources"
    {:ok, view, _} = live(conn, path)
    view |> element("#rename-page-#{page.id}") |> render_click()

    view
    |> form("#rename-page-form", page: %{title: "  Les volcans  "})
    |> render_submit()

    refute has_element?(view, "#rename-page-modal")
    assert has_element?(view, "#lesson-page-#{page.id} .learning-card-name", "Les volcans")
    saved = Repo.get!(Study.Page, page.id)
    assert saved.title == "Les volcans"
    assert saved.filename == "page-1.png"
    {:ok, reloaded, _} = live(conn, path)
    assert has_element?(reloaded, "#lesson-page-#{page.id} .learning-card-name", "Les volcans")
  end

  test "cancel leaves the name unchanged and blank names are rejected", %{
    conn: conn,
    lesson: lesson,
    page: page
  } do
    {:ok, view, _} = live(conn, "/alice/lecons/#{lesson.id}?onglet=ressources")
    view |> element("#rename-page-#{page.id}") |> render_click()
    view |> element("#cancel-rename-page") |> render_click()
    refute has_element?(view, "#rename-page-modal")
    assert Repo.get!(Study.Page, page.id).title == "page-1"
    view |> element("#rename-page-#{page.id}") |> render_click()
    view |> form("#rename-page-form", page: %{title: "   "}) |> render_submit()
    assert has_element?(view, "#rename-page-form")
    assert Repo.get!(Study.Page, page.id).title == "page-1"
  end

  test "rename is scoped to the profile and lesson and validates length", %{
    lesson: lesson,
    resource: resource
  } do
    assert {:error, :not_found} =
             Resources.rename(Ecto.UUID.generate(), lesson.id, resource.id, %{title: "Changed"})

    assert {:error, :not_found} =
             Resources.rename(lesson.profile_id, Ecto.UUID.generate(), resource.id, %{
               title: "Changed"
             })

    assert {:error, %Ecto.Changeset{}} =
             Resources.rename(lesson.profile_id, lesson.id, resource.id, %{
               title: String.duplicate("a", 241)
             })

    assert Repo.get!(Study.Resource, resource.id).title == nil
  end
end

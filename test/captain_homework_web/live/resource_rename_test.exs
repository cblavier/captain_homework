defmodule CaptainHomeworkWeb.ResourceRenameTest do
  use CaptainHomeworkWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Repo, Resources, Study}

  setup do
    lesson = lesson(profile())

    resource =
      Repo.insert!(%Study.Resource{lesson_id: lesson.id, filename: "cours.pdf", status: "ready"})

    %{lesson: lesson, resource: resource}
  end

  test "rename persists the display name and preserves the original filename", %{
    conn: conn,
    lesson: lesson,
    resource: resource
  } do
    path = "/alice/lecons/#{lesson.id}?onglet=ressources"
    {:ok, view, _} = live(conn, path)
    view |> element("#rename-resource-#{resource.id}") |> render_click()

    view
    |> form("#rename-resource-form", resource: %{title: "  Les volcans  "})
    |> render_submit()

    refute has_element?(view, "#rename-resource-modal")
    assert has_element?(view, "#resource-#{resource.id} h2", "Les volcans")
    saved = Repo.get!(Study.Resource, resource.id)
    assert saved.title == "Les volcans"
    assert saved.filename == "cours.pdf"
    {:ok, reloaded, _} = live(conn, path)
    assert has_element?(reloaded, "#resource-#{resource.id} h2", "Les volcans")
  end

  test "cancel leaves the name unchanged and blank names are rejected", %{
    conn: conn,
    lesson: lesson,
    resource: resource
  } do
    {:ok, view, _} = live(conn, "/alice/lecons/#{lesson.id}?onglet=ressources")
    view |> element("#rename-resource-#{resource.id}") |> render_click()
    view |> element("#cancel-rename-resource") |> render_click()
    refute has_element?(view, "#rename-resource-modal")
    assert Repo.get!(Study.Resource, resource.id).title == nil
    view |> element("#rename-resource-#{resource.id}") |> render_click()
    view |> form("#rename-resource-form", resource: %{title: "   "}) |> render_submit()
    assert has_element?(view, "#rename-resource-form")
    assert Repo.get!(Study.Resource, resource.id).title == nil
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

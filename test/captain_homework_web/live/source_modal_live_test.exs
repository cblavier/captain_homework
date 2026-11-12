defmodule CaptainHomeworkWeb.SourceModalLiveTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.Repo

  test "lesson original preview returns to the editor with unsaved text", %{conn: conn} do
    lesson = lesson(profile())
    page = page(lesson)
    {:ok, view, _} = live(conn, "/alice/lecons/#{lesson.id}?onglet=cours")

    view |> element("#lesson-page-#{page.id} button[phx-click='edit_page']") |> render_click()
    view |> form("#page-text-form", %{text: "Texte modifié"}) |> render_change()
    view |> element("#preview-original-page") |> render_click()
    assert has_element?(view, "#source-modal img[src='/alice/pages/#{page.id}']")

    view |> element("#source-modal button[aria-label='Fermer']") |> render_click()
    assert has_element?(view, "#page-modal #page-text", "Texte modifié")
    refute has_element?(view, "#source-modal")
  end

  test "reference previews close within the reference", %{conn: conn} do
    lesson = lesson(profile())
    reference = reference_exam(profile())

    page =
      page(lesson)
      |> Ecto.Changeset.change(kind: "example", lesson_id: nil, reference_exam_id: reference.id)
      |> Repo.update!()

    {:ok, view, _} = live(conn, "/alice/references/#{reference.id}")

    view |> element("#open-example-#{page.id}") |> render_click()
    assert has_element?(view, "#source-modal img[src='/alice/pages/#{page.id}']")
    view |> element("#source-modal button[aria-label='Fermer']") |> render_click()
    refute has_element?(view, "#source-modal")
    assert has_element?(view, "#open-example-#{page.id}")
  end
end

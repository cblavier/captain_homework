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

  test "example previews close within the lesson", %{conn: conn} do
    lesson = lesson(profile())
    page = page(lesson) |> Ecto.Changeset.change(kind: "example") |> Repo.update!()
    {:ok, view, _} = live(conn, "/alice/lecons/#{lesson.id}")

    view |> element("#open-example-#{page.id}") |> render_click()
    assert has_element?(view, "#source-modal img[src='/alice/pages/#{page.id}']")
    view |> element("#source-modal button[aria-label='Fermer']") |> render_click()
    refute has_element?(view, "#source-modal")
    assert has_element?(view, "#open-example-#{page.id}")
  end

  test "a correction source opens and closes without leaving the exam", %{conn: conn} do
    lesson = lesson(profile())
    page = page(lesson)
    question = Map.put(question(), "source_page_ids", [page.id])

    exam =
      exam(lesson, [question])
      |> Ecto.Changeset.change(
        status: "completed",
        score: 20.0,
        corrections: %{
          "q1" => %{"points" => question["points"], "feedback" => "Bien", "expected" => "Réponse"}
        }
      )
      |> Repo.update!()

    {:ok, view, _} = live(conn, "/alice/controles/#{exam.id}")
    selector = "#open-source-q1-#{page.id}"
    view |> element(selector) |> render_click()

    assert has_element?(
             view,
             "#source-modal[role=dialog] #source-content img[src='/alice/pages/#{page.id}']"
           )

    view |> element("#source-modal button[aria-label='Fermer']") |> render_click()
    refute has_element?(view, "#source-modal")
    assert has_element?(view, selector)

    unrelated = page(lesson)
    render_click(view, "open_source", %{"id" => unrelated.id})
    refute has_element?(view, "#source-modal")
  end
end

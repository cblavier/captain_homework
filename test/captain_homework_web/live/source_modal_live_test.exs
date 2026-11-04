defmodule CaptainHomeworkWeb.SourceModalLiveTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.Repo

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

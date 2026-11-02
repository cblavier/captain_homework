defmodule CaptainHomeworkWeb.CorrectionSourcesLiveTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Repo, Study}

  test "lesson sources open original pages only after the control is corrected", %{conn: conn} do
    p = profile()
    l = lesson(p)
    first = page(l)
    pg = page(l)
    q = question() |> Map.put("source_page_ids", [pg.id, pg.id])
    e = exam(l, [q])
    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
    refute has_element?(view, "#question-sources-q1")

    e
    |> Ecto.Changeset.change(
      status: "completed",
      score: 20.0,
      corrections: %{
        "q1" => %{"points" => 4, "feedback" => "Correct.", "expected" => q["answer"]}
      }
    )
    |> Repo.update!()

    {:ok, corrected, _} = live(conn, "/alice/controles/#{e.id}")

    assert has_element?(
             corrected,
             "#question-sources-q1 a[href='/alice/pages/#{pg.id}'][target='_blank'][rel='noopener noreferrer']",
             "Leçon : La cellule"
           )

    assert has_element?(corrected, "#question-q1 .expected + .correction-sources")
    assert has_element?(corrected, "#question-q1 .correction-correct", "4 / 4")
    assert has_element?(corrected, "#question-sources-q1 .source-page-number", "(page 2)")
    assert length(CaptainHomework.Exams.Sources.for_exam(e, p.id)["q1"]) == 1

    Repo.delete!(first)
    assert [%{page_number: 1}] = CaptainHomework.Exams.Sources.for_exam(e, p.id)["q1"]
    last = page(l)
    assert {:ok, _} = Study.move_page(p.id, l.id, last.id, "previous")
    assert [%{page_number: 2}] = CaptainHomework.Exams.Sources.for_exam(e, p.id)["q1"]
  end

  test "document sources link only to the page", %{conn: conn} do
    p = profile()
    l = lesson(p)

    resource =
      Repo.insert!(%Study.Resource{
        lesson_id: l.id,
        filename: "Fiche.pdf",
        storage_key: "fiche.pdf",
        status: "ready"
      })

    {:ok, pg} =
      Study.add_page(l, %{
        kind: "resource",
        resource_id: resource.id,
        filename: "Page 2",
        storage_key: "page-2.png",
        content_type: "image/png",
        status: "ready"
      })

    q = question() |> Map.put("source_page_ids", [pg.id])

    e =
      exam(l, [q])
      |> Ecto.Changeset.change(
        status: "completed",
        score: 20.0,
        corrections: %{
          "q1" => %{"points" => 4, "feedback" => "Correct.", "expected" => q["answer"]}
        }
      )
      |> Repo.update!()

    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")

    assert has_element?(
             view,
             "#question-sources-q1 a[href='/alice/pages/#{pg.id}']",
             "Document : Fiche.pdf"
           )

    refute has_element?(view, "#question-sources-q1 a[href='/alice/ressources/#{resource.id}']")
    refute has_element?(view, "#question-sources-q1 .source-page-number")
  end

  test "unknown, deleted and other-child source IDs are not attributed" do
    p = profile()
    l = lesson(p)
    other_page = page(lesson(profile("Marius")))
    removed = page(l)
    Repo.delete!(removed)
    q = question() |> Map.put("source_page_ids", [other_page.id, removed.id, "invalid"])
    e = exam(l, [q, question("legacy")])
    assert CaptainHomework.Exams.Sources.for_exam(e, p.id) == %{"q1" => [], "legacy" => []}
  end
end

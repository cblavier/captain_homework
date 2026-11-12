defmodule CaptainHomeworkWeb.ReferenceExamsLiveTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.ReferenceExams

  test "create and rename a dated reference from its subject", %{conn: conn} do
    {:ok, view, _} = live(conn, "/alice/matieres/svt?onglet=references")

    refute has_element?(view, "#new-reference")
    view |> element("#new-reference-button") |> render_click()
    assert has_element?(view, "#reference-modal #new-reference")

    view
    |> form("#new-reference", reference: %{title: "Cellules", date: "2026-10-12"})
    |> render_submit()

    [reference] = ReferenceExams.list(profile().id, "svt")
    assert_redirect(view, "/alice/references/#{reference.id}")
    {:ok, detail, _} = live(conn, "/alice/references/#{reference.id}")
    assert has_element?(detail, "#reference-title", "Cellules")

    detail
    |> form("#edit-reference", reference: %{title: "Le vivant", date: "2026-10-13"})
    |> render_submit()

    assert has_element?(detail, "#reference-title", "Le vivant")
    {:ok, subject, _} = live(conn, "/alice/matieres/svt?onglet=references")

    assert has_element?(
             subject,
             "#reference-list a[href='/alice/references/#{reference.id}']",
             "Le vivant"
           )

    assert has_element?(subject, "#reference-list", "13/10/2026")
  end

  test "subject tabs preserve their URL and restore streamed lists", %{conn: conn} do
    lesson = lesson(profile())
    reference = reference_exam(profile())
    {:ok, view, _} = live(conn, "/alice/matieres/svt")
    assert has_element?(view, "#subject-tab-lecons[aria-current=page]")
    assert has_element?(view, "#lessons a[href='/alice/lecons/#{lesson.id}']")
    refute has_element?(view, "#subject-references")
    view |> element("#subject-tab-references") |> render_click()
    assert_patch(view, "/alice/matieres/svt?onglet=references")
    assert has_element?(view, "#subject-tab-references[aria-current=page]")
    assert has_element?(view, "#reference-list a[href='/alice/references/#{reference.id}']")
    refute has_element?(view, "#subject-lessons")
    view |> element("#subject-tab-lecons") |> render_click()
    assert has_element?(view, "#lessons a[href='/alice/lecons/#{lesson.id}']")
    refute has_element?(view, "#new-reference")
    view |> element("#subject-tab-references") |> render_click()
    assert has_element?(view, "#reference-list a[href='/alice/references/#{reference.id}']")
    {:ok, reloaded, _} = live(conn, "/alice/matieres/svt?onglet=references")
    assert has_element?(reloaded, "#subject-tab-references[aria-current=page]")
  end

  test "creation offers only references for this child and subject and preserves the selection",
       %{conn: conn} do
    l = lesson(profile())
    reference = reference_exam(profile())
    other = reference_exam(profile("Marius"))
    english = reference_exam(profile(), "anglais")
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}/controle")
    assert has_element?(view, "#new-exam-title", "Nouvelle évaluation")
    assert has_element?(view, "#reference-exam-id option[value=''][selected]", "Aucun")
    assert has_element?(view, "#reference-exam-id option[value='#{reference.id}']")
    refute has_element?(view, "#reference-exam-id option[value='#{other.id}']")
    refute has_element?(view, "#reference-exam-id option[value='#{english.id}']")
    view |> form("#exam-setup", %{reference_exam_id: reference.id}) |> render_change()
    assert has_element?(view, "#reference-exam-id option[value='#{reference.id}'][selected]")
    view |> form("#exam-setup", %{format: "flashcard"}) |> render_change()
    refute has_element?(view, "#reference-selection")
    {:ok, lesson_view, _} = live(conn, "/alice/lecons/#{l.id}")
    refute has_element?(lesson_view, "#upload-examples")
    assert has_element?(lesson_view, "#lesson-tab-controles", "Évaluations")
  end
end

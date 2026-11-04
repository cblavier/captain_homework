defmodule CaptainHomeworkWeb.SymbolPaletteTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import CaptainHomework.Fixtures
  import Phoenix.LiveViewTest
  alias CaptainHomework.{Repo, Study, QuestionDefinitions}

  test "classic palettes stay separate from patched fields and symbolic answers persist", %{
    conn: conn
  } do
    lesson = lesson(profile())
    q = question("q1", "definition") |> Map.put("prompt", "Complète avec ∈ ou ∉.")
    slots = question("q2", "cloze") |> Map.put("slots", ["A", "B"])
    exam = exam(lesson, [q, slots, question("q3", "mcq")])
    {:ok, view, _} = live(conn, "/alice/controles/#{exam.id}")

    for id <- ~w(q1 q2) do
      assert has_element?(
               view,
               "#symbols-#{id}-palette[phx-hook=SymbolPalette][phx-update=ignore]"
             )

      assert has_element?(view, "#symbols-#{id}-toggle[aria-expanded=false][type=button]")
      assert has_element?(view, "#symbols-#{id}-panel[hidden]")
    end

    refute has_element?(view, "#symbols-q1-fields[phx-update=ignore]")
    refute has_element?(view, "#symbols-q3")

    view
    |> form("#exam-answers", answers: %{"q1" => "D ∉ (AB)", "q2" => %{"A" => "[AB)", "B" => "ñ"}})
    |> render_change()

    saved = Study.get_exam!(lesson.profile_id, exam.id)
    assert saved.answers["q1"] == "D ∉ (AB)"
    assert saved.answers["q2"] == %{"A" => "[AB)", "B" => "ñ"}
    {:ok, reloaded, _} = live(conn, "/alice/controles/#{exam.id}")
    assert has_element?(reloaded, "#answer-q1[value='D ∉ (AB)']")
  end

  test "flashcards expose a fresh palette per question and disable it during correction", %{
    conn: conn
  } do
    lesson = lesson(profile())

    exam =
      exam(lesson, [question("q1"), question("q2")])
      |> Ecto.Changeset.change(format: "flashcard")
      |> Repo.update!()

    {:ok, view, _} = live(conn, "/alice/controles/#{exam.id}")
    assert has_element?(view, "#flashcard-symbols-q1-toggle[aria-expanded=false]")
    view |> form("#flashcard-answer", answers: %{"q1" => "∉"}) |> render_change()
    assert Study.get_exam!(lesson.profile_id, exam.id).answers["q1"] == "∉"

    Repo.get!(Study.Exam, exam.id)
    |> Ecto.Changeset.change(status: "grading", grading_started_at: DateTime.utc_now())
    |> Repo.update!()

    send(view.pid, :refresh_exam)
    assert has_element?(view, "#flashcard-symbols-q1-palette[data-disabled=true]")
  end

  test "both preview modes use the shared palette", %{conn: conn} do
    profile()
    {:ok, _} = QuestionDefinitions.seed!()
    type = Enum.find(QuestionDefinitions.list(), &(&1.name == "Définition"))
    {:ok, view, _} = live(conn, "/alice/parametres/types/#{type.id}")

    for mode <- ~w(classic flashcard) do
      view |> form("#type-preview-mode", %{mode: mode}) |> render_change()
      assert has_element?(view, "#preview-text-symbols-palette[phx-hook=SymbolPalette]")
      assert has_element?(view, "#preview-text-symbols-fields #preview-answer")
    end
  end
end

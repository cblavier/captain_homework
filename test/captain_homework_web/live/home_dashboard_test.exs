defmodule CaptainHomeworkWeb.HomeDashboardTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.Repo

  test "home shows the pupil's evaluations, pages backwards and retains the feed across tabs", %{
    conn: conn
  } do
    lesson = lesson(profile(), "anglais")

    controls =
      for index <- 1..12 do
        exam(lesson)
        |> Ecto.Changeset.change(
          inserted_at: DateTime.add(~U[2026-11-01 12:00:00.000000Z], index),
          format: if(index == 12, do: "flashcard", else: "classic")
        )
        |> Repo.update!()
      end

    other = exam(lesson(profile("Marius")))
    {:ok, view, _} = live(conn, "/alice")
    assert has_element?(view, "#home-dashboard[data-panel='subjects']")
    assert has_element?(view, "#home-subjects #subject-anglais")
    assert has_element?(view, "#home-exam-list > a", "Anglais")
    assert has_element?(view, "#home-exam-list .flashcard-badge", "Flash cards")
    refute has_element?(view, "#home_exams-#{other.id}")

    assert render(view)
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("#home-exam-list > a")
           |> Enum.count() == 8

    for control <- Enum.take(controls, -8) do
      assert has_element?(
               view,
               "#home_exams-#{control.id}[href='/alice/controles/#{control.id}']"
             )

      assert has_element?(view, "#home-exam-status-#{control.id}", "Commencer")
    end

    refute has_element?(view, "#home_exams-#{hd(controls).id}")
    view |> element("#home-panel-exams") |> render_click()
    assert has_element?(view, "#home-dashboard[data-panel='exams']")
    assert has_element?(view, "#home-panel-exams[aria-pressed='true']")
    assert has_element?(view, "#home-exams-more")
    view |> element("#home-exams-more") |> render_click()
    refute has_element?(view, "#home-exams-more")

    view |> element("#home-panel-subjects") |> render_click()
    view |> element("#home-panel-exams") |> render_click()

    for control <- controls, do: assert(has_element?(view, "#home_exams-#{control.id}"))

    assert render(view)
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("#home-exam-list > a")
           |> Enum.count() == 12
  end

  test "visible evaluation status updates when generation or grading finishes", %{conn: conn} do
    control =
      exam(lesson(profile())) |> Ecto.Changeset.change(status: "generating") |> Repo.update!()

    {:ok, view, _} = live(conn, "/alice")
    assert has_element?(view, "#home-exam-status-#{control.id}", "Préparation…")
    assert has_element?(view, "#subject-svt-exam-summary", "1 évaluation non rendue")

    control |> Ecto.Changeset.change(status: "completed", score: 14.0) |> Repo.update!()
    Phoenix.PubSub.broadcast(CaptainHomework.PubSub, "exam:#{control.id}", :exam_updated)
    assert has_element?(view, "#home-exam-status-#{control.id}.score-badge", "14")
    assert has_element?(view, "#subject-svt-exam-summary", "1 évaluation corrigée")
  end

  test "empty history has no more button", %{conn: conn} do
    {:ok, view, _} = live(conn, "/alice")
    assert has_element?(view, "#home-exams-empty")
    refute has_element?(view, "#home-exams-more")
  end

  test "subject cards distinguish corrected and unsubmitted evaluations", %{conn: conn} do
    pupil = profile()

    for {subject, statuses} <- [
          {"anglais", ~w(completed completed in_progress in_progress in_progress)},
          {"francais", ~w(in_progress in_progress in_progress)},
          {"mathematiques", ~w(completed completed)},
          {"svt", ~w(completed in_progress)}
        ] do
      chapter = lesson(pupil, subject)

      for status <- statuses do
        exam(chapter)
        |> Ecto.Changeset.change(status: status, score: if(status == "completed", do: 14.0))
        |> Repo.update!()
      end
    end

    {:ok, view, _} = live(conn, "/alice")

    for {subject, text} <- [
          {"anglais", "2 évaluations corrigées, 3 non rendues"},
          {"francais", "3 évaluations non rendues"},
          {"mathematiques", "2 évaluations corrigées"},
          {"svt", "1 évaluation corrigée, 1 non rendue"},
          {"histoire-geo", "0 évaluation"}
        ] do
      assert has_element?(view, "#subject-#{subject}-exam-summary", text)
    end
  end
end

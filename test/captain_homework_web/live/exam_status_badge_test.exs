defmodule CaptainHomeworkWeb.ExamStatusBadgeTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.Repo

  test "start and resume badges reflect actual answers in both exam modes", %{conn: conn} do
    lesson = lesson(profile())

    controls =
      for format <- ["classic", "flashcard"],
          {answers, expected} <- [
            {%{}, "Commencer"},
            {%{"q1" => nil, "q2" => " \n "}, "Commencer"},
            {%{"q1" => %{"a" => "", "b" => " "}}, "Commencer"},
            {%{"obsolete-question" => "ancienne réponse"}, "Commencer"},
            {%{"q1" => "Une réponse", "q2" => ""}, "Reprendre"},
            {%{"q1" => %{"a" => "", "b" => "une légende"}}, "Reprendre"},
            {%{"q1" => %{"storage_key" => "photo.webp"}}, "Reprendre"},
            {%{"q1" => %{"storage_key" => "recording.webm"}}, "Reprendre"}
          ] do
        control =
          exam(lesson, [question("q1"), question("q2")])
          |> Ecto.Changeset.change(format: format, answers: answers)
          |> Repo.update!()

        {control.id, expected}
      end

    {:ok, view, _} = live(conn, "/alice/lecons/#{lesson.id}?onglet=controles")

    for {id, expected} <- controls do
      assert has_element?(view, "#exam-status-#{id}", expected)
    end
  end

  test "preparation, partial generation and grading keep their specific badges", %{conn: conn} do
    lesson = lesson(profile())

    controls =
      for {status, expected} <- [
            {"generating", "Préparation…"},
            {"generation_partial", "À compléter"},
            {"grading", "Correction…"}
          ] do
        control = exam(lesson) |> Ecto.Changeset.change(status: status) |> Repo.update!()
        {control.id, expected}
      end

    {:ok, view, _} = live(conn, "/alice/lecons/#{lesson.id}?onglet=controles")

    for {id, expected} <- controls do
      assert has_element?(view, "#exam-status-#{id}", expected)
    end
  end
end

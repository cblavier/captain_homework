defmodule CaptainHomeworkWeb.GenerationNotificationsTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.Repo
  alias CaptainHomework.Exams.Generation

  setup do
    lesson = lesson(profile())
    exam = exam(lesson)
    %{lesson: lesson, exam: exam}
  end

  defp finished(exam) do
    Phoenix.PubSub.broadcast(
      CaptainHomework.PubSub,
      "exam_generation",
      {:exam_generation_finished,
       Map.take(exam, [:id, :lesson_id, :status, :generation_started_at])}
    )
  end

  test "success appears on another page with a link and can be dismissed", %{
    conn: conn,
    exam: exam
  } do
    {:ok, view, _} = live(conn, "/alice")
    finished(exam)
    assert has_element?(view, "#flash-info.info a[href='/alice/controles/#{exam.id}']")
    view |> element("#dismiss-flash-info") |> render_click()
    refute has_element?(view, "#flash-info")
    finished(exam)
    refute has_element?(view, "#flash-info")
  end

  test "an interrupted generation sends a red notification with a link", %{conn: conn, exam: exam} do
    exam =
      exam
      |> Ecto.Changeset.change(status: "generating", generation_started_at: DateTime.utc_now())
      |> Repo.update!()

    {:ok, view, _} = live(conn, "/alice")
    Generation.interrupt(exam, "Service indisponible")
    assert has_element?(view, "#flash-error.error a[href='/alice/controles/#{exam.id}']")
  end

  test "the current control suppresses its notification but another control still notifies", %{
    conn: conn,
    exam: exam,
    lesson: lesson
  } do
    {:ok, view, _} = live(conn, "/alice/controles/#{exam.id}")
    finished(exam)
    refute has_element?(view, "#flash-info")
    other = exam(lesson)
    finished(other)
    assert has_element?(view, "#flash-info a[href='/alice/controles/#{other.id}']")
  end

  test "notifications also appear in question type settings", %{conn: conn, exam: exam} do
    {:ok, view, _} = live(conn, "/alice/parametres/types")
    finished(exam)
    assert has_element?(view, "#flash-info a[href='/alice/controles/#{exam.id}']")
  end
end

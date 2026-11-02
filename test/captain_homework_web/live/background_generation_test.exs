defmodule CaptainHomeworkWeb.BackgroundGenerationTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Exams, Repo, Study}
  alias CaptainHomework.Exams.{Generation, GenerationJobs}

  setup do
    old = Application.fetch_env!(:captain_homework, :ai_provider)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.BlockingGenerationAI)
    Application.put_env(:captain_homework, :generation_test_pid, self())

    on_exit(fn ->
      Application.put_env(:captain_homework, :ai_provider, old)
      Application.delete_env(:captain_homework, :generation_test_pid)
    end)

    l = lesson(profile())
    page(l)
    %{lesson: l}
  end

  defp await_status(id, status) do
    exam = Repo.get!(Study.Exam, id)

    if exam.status == status do
      exam
    else
      assert_receive :exam_updated, 2000
      await_status(id, status)
    end
  end

  test "closing the creation view and reloading does not stop generation", %{
    conn: conn,
    lesson: l
  } do
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}/controle")
    view |> form("#exam-setup", instructions: "") |> render_submit()
    {path, _} = assert_redirect(view)
    [exam] = Study.get_lesson!(l.profile_id, l.id).exams
    assert path == "/alice/controles/#{exam.id}"
    assert_receive {:generation_waiting, worker, []}
    ref = Process.monitor(worker)
    view_ref = Process.monitor(view.pid)
    Process.exit(view.pid, :shutdown)
    assert_receive {:DOWN, ^view_ref, :process, _, _}
    assert GenerationJobs.running?(exam)

    exam
    |> Ecto.Changeset.change(
      generation_errors: ["Question q1 : effort attendu direct, effort constaté short."]
    )
    |> Repo.update!()

    {:ok, refreshed, _} = live(conn, path)
    refute has_element?(refreshed, "#generation-errors")
    assert has_element?(refreshed, "#generation-stage", "Préparation des questions …")
    Phoenix.PubSub.subscribe(CaptainHomework.PubSub, "exam:#{exam.id}")
    questions = for n <- 1..10, do: question("q#{n}") |> Map.put("prompt", "Question #{n}")
    send(worker, {:generation_reply, {:ok, questions}})
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 2000
    ready = await_status(exam.id, "in_progress")
    assert length(ready.questions) == 10
    assert has_element?(refreshed, "#exam-answers")
    _ = :sys.get_state(GenerationJobs)
  end

  test "old internal effort diagnostics are translated when generation stops", %{
    conn: conn,
    lesson: l
  } do
    exam = exam(l)

    exam
    |> Ecto.Changeset.change(
      status: "generation_partial",
      generation_target: 10,
      generation_errors: [
        "Question q1 : effort attendu direct, effort constaté short. Réécris la consigne."
      ]
    )
    |> Repo.update!()

    {:ok, view, _} = live(conn, "/alice/controles/#{exam.id}")
    assert has_element?(view, "#generation-errors", "Réessaie les questions manquantes")
    refute has_element?(view, "#generation-errors", "effort constaté")
    assert has_element?(view, "#resume-generation")
  end

  test "a crashed worker immediately exposes saved questions for recovery", %{lesson: l} do
    {:ok, exam} = Exams.generate(l.profile_id, l.id, 2, "", background: true)
    Phoenix.PubSub.subscribe(CaptainHomework.PubSub, "exam:#{exam.id}")
    assert_receive {:generation_waiting, worker, []}
    send(worker, {:generation_reply, {:ok, [question("kept")]}})
    assert_receive {:generation_waiting, ^worker, [kept]}, 2000
    ref = Process.monitor(worker)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    partial = await_status(exam.id, "generation_partial")
    assert partial.questions == [kept]
    assert partial.error =~ "interrompue"
    _ = :sys.get_state(GenerationJobs)
    {:ok, resumed} = Exams.resume_generation(l.profile_id, exam.id, background: true)
    assert {:error, _} = Exams.resume_generation(l.profile_id, exam.id, background: true)
    assert_receive {:generation_waiting, next_worker, [^kept]}
    Generation.interrupt(exam, "Old run must not affect the resumed job")
    assert Repo.get!(Study.Exam, resumed.id).status == "generating"
    next_ref = Process.monitor(next_worker)
    next = question("next") |> Map.put("prompt", "Question suivante")
    send(next_worker, {:generation_reply, {:ok, [next]}})
    assert_receive {:DOWN, ^next_ref, :process, ^next_worker, :normal}, 2000
    complete = await_status(exam.id, "in_progress")
    assert hd(complete.questions) == kept
    assert length(complete.questions) == 2
    _ = :sys.get_state(GenerationJobs)
  end

  test "the deadline stops a stalled worker and permits recovery", %{lesson: l} do
    {:ok, exam} = Exams.generate(l.profile_id, l.id, 1, "", background: true)
    Phoenix.PubSub.subscribe(CaptainHomework.PubSub, "exam:#{exam.id}")
    assert_receive {:generation_waiting, worker, []}
    ref = Process.monitor(worker)

    {job_ref, _} =
      Enum.find(:sys.get_state(GenerationJobs), fn {_, job} -> job.exam.id == exam.id end)

    send(GenerationJobs, {:timeout, job_ref})
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}, 2000
    partial = await_status(exam.id, "generation_partial")
    assert partial.error =~ "délai maximal"
    _ = :sys.get_state(GenerationJobs)
  end
end

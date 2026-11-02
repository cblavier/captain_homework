defmodule CaptainHomeworkWeb.FlashcardLiveTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Repo, Study, Exams}

  setup do
    old = Application.fetch_env!(:captain_homework, :ai_provider)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.TestAI)
    on_exit(fn -> Application.put_env(:captain_homework, :ai_provider, old) end)
    :ok
  end

  defp flash_exam(l) do
    exam(l, Enum.map(1..2, &(question("q#{&1}", "definition") |> Map.put("points", 1))))
    |> Ecto.Changeset.change(format: "flashcard")
    |> Repo.update!()
  end

  test "format defaults to classic and flashcard disables intermediate and long types", %{
    conn: conn
  } do
    l = lesson(profile())
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}/controle")
    assert has_element?(view, "#exam-format-classic[checked]")
    view |> form("#exam-setup") |> render_change(%{"format" => "flashcard"})
    assert has_element?(view, "#exam-format-flashcard[checked]")
    assert has_element?(view, "#flashcard-help")

    for type <- CaptainHomework.SubjectQuestionTypes.list(l.profile_id, l.subject) do
      selector = "#question-type-#{type["id"]}"

      if type["work_duration"] == "quick" do
        assert has_element?(view, selector <> "[checked]:not([disabled])")
      else
        assert has_element?(view, selector <> "[disabled]:not([checked])")
      end
    end

    view |> form("#exam-setup") |> render_change(%{"format" => "classic"})
    refute has_element?(view, "#question-types input[disabled]")
    assert has_element?(view, "#exam-format-classic[checked]")
  end

  test "one card at a time, persisted flip, next card and final correction", %{conn: conn} do
    e = flash_exam(lesson(profile()))
    Phoenix.PubSub.subscribe(CaptainHomework.PubSub, "exam:#{e.id}")
    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
    assert has_element?(view, "#flashcard-q1")
    assert has_element?(view, ".page-shell-immersive #flashcard-player")
    assert has_element?(view, "#close-flashcards[href='/alice/lecons/#{e.lesson_id}']")
    assert has_element?(view, "#flashcard-actions #validate-card[form=flashcard-answer]")
    refute has_element?(view, "#child-picker")
    refute has_element?(view, "#exam-footer")
    refute has_element?(view, ".app-brand-footer")
    refute has_element?(view, "#flashcard-session [autofocus]")
    refute has_element?(view, "#flashcard-q2")
    refute has_element?(view, "#exam-answers")
    refute has_element?(view, "#finish-exam")
    refute has_element?(view, "#flashcard-correction")
    view |> form("#flashcard-answer", %{"answers" => %{"q1" => "quart"}}) |> render_submit()
    await_correction(e, "q1")
    send(view.pid, :refresh_exam)
    assert has_element?(view, "#flashcard-q1 .is-flipped")
    assert has_element?(view, "#flashcard-correction .points", "0,25 / 1")
    assert has_element?(view, "#flashcard-answer fieldset[disabled]")
    assert has_element?(view, "#next-card", "Carte suivante")
    {:ok, reloaded, _} = live(conn, "/alice/controles/#{e.id}")
    assert has_element?(reloaded, "#flashcard-q1 .is-flipped")
    reloaded |> element("#next-card") |> render_click()
    assert has_element?(reloaded, "#flashcard-q2")
    refute has_element?(reloaded, "#flashcard-q1")
    refute has_element?(reloaded, ".is-flipped")

    reloaded
    |> form("#flashcard-answer", %{"answers" => %{"q2" => "trois quarts"}})
    |> render_submit()

    await_correction(e, "q2")
    send(reloaded.pid, :refresh_exam)
    assert has_element?(reloaded, "#next-card", "Voir mon résultat")
    refute has_element?(reloaded, ".total-score")
    reloaded |> element("#next-card") |> render_click()
    refute has_element?(reloaded, "#flashcard-session")
    refute has_element?(reloaded, ".page-shell-immersive")
    assert has_element?(reloaded, "#child-picker")
    assert has_element?(reloaded, ".app-brand-footer")
    assert has_element?(reloaded, ".total-score", "10")
    assert has_element?(reloaded, "#question-q1 .correction")
    assert has_element?(reloaded, "#question-q2 .correction")
    assert has_element?(reloaded, "#exam-appreciation")
  end

  test "closing the player returns to the lesson and preserves the current answer", %{conn: conn} do
    e = flash_exam(lesson(profile()))
    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
    view |> form("#flashcard-answer") |> render_change(%{"answers" => %{"q1" => "Brouillon"}})
    view |> element("#close-flashcards") |> render_click()
    assert_redirect(view, "/alice/lecons/#{e.lesson_id}")
    {:ok, resumed, _} = live(conn, "/alice/controles/#{e.id}")
    assert has_element?(resumed, "#flashcard-response", "Brouillon")
    refute has_element?(resumed, ".is-flipped")
  end

  test "question formats include QCM and slots and listing shows both badges", %{conn: conn} do
    l = lesson(profile())
    classic = exam(l)

    mcq =
      question("qcm", "mcq")
      |> Map.merge(%{"points" => 1, "options" => ["A", "B"], "answer" => "B"})

    cloze =
      question("holes", "cloze")
      |> Map.merge(%{"points" => 1, "slots" => ["1"], "text" => "Une {{1}}."})

    e = exam(l, [mcq, cloze]) |> Ecto.Changeset.change(format: "flashcard") |> Repo.update!()
    {:ok, list, _} = live(conn, "/alice/lecons/#{l.id}")
    assert has_element?(list, "#exam-format-#{classic.id}", "Classique")
    assert has_element?(list, "#exam-format-#{e.id}", "Flashcard")
    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
    assert has_element?(view, "#flashcard-option-0[type=radio]")
    assert has_element?(view, "#flashcard-option-1[value=B]")
    {:ok, graded} = Exams.Flashcards.submit(l.profile_id, e.id, "qcm", "A", sync: true)
    assert graded.corrections["qcm"]["points"] == 0
    Exams.Flashcards.advance(l.profile_id, e.id, "qcm")
    send(view.pid, :refresh_exam)
    assert has_element?(view, "#flashcard-slot-0[name='answers[holes][1]']")
  end

  defp await_correction(exam, id) do
    if Map.has_key?(Study.get_exam!(profile().id, exam.id).corrections, id) do
      :ok
    else
      assert_receive :exam_updated, 2000
      await_correction(exam, id)
    end
  end

  test "validation flips to an in-card spinner before correction and recovers from errors", %{
    conn: conn
  } do
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.BlockingGradeAI)
    Application.put_env(:captain_homework, :grading_test_pid, self())
    on_exit(fn -> Application.delete_env(:captain_homework, :grading_test_pid) end)
    e = flash_exam(lesson(profile()))
    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")

    for outcome <- [:fail_grading, :finish_grading] do
      view |> form("#flashcard-answer", %{"answers" => %{"q1" => "quart"}}) |> render_submit()
      assert_receive {:grading_waiting, worker}
      on_exit(fn -> send(worker, :fail_grading) end)
      ref = Process.monitor(worker)
      assert has_element?(view, "#flashcard-q1 .is-flipped.is-grading")
      assert has_element?(view, ".flashcard-back #flashcard-grading[role=status] .spinner")
      assert has_element?(view, "#flashcard-grading[aria-label='Correction en cours']")
      refute has_element?(view, "#flashcard-grading p")
      refute has_element?(view, "p.notice[role=status]")
      refute has_element?(view, "#flashcard-correction")
      refute has_element?(view, "#next-card")

      send(worker, outcome)
      assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 2000
      send(view.pid, :refresh_exam)
      refute has_element?(view, ".is-grading")

      if outcome == :fail_grading do
        refute has_element?(view, ".is-flipped")
        assert has_element?(view, "#flashcard-response", "quart")
        refute has_element?(view, "#flashcard-answer fieldset[disabled]")
      else
        assert has_element?(view, ".is-flipped #flashcard-correction")
        refute has_element?(view, "#flashcard-grading")
        assert has_element?(view, "#next-card")
      end
    end
  end
end

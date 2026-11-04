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

  defp flash_exam(l, count \\ 2) do
    exam(l, Enum.map(1..count, &(question("q#{&1}", "definition") |> Map.put("points", 1))))
    |> Ecto.Changeset.change(format: "flashcard")
    |> Repo.update!()
  end

  test "the stack shrinks to one card then none, preserving the final transition", %{conn: conn} do
    e = flash_exam(lesson(profile()), 4)

    corrections =
      Map.new(e.questions, fn q ->
        {q["id"],
         %{"fraction" => 1, "points" => 1, "feedback" => "Correct", "expected" => q["answer"]}}
      end)

    e |> Ecto.Changeset.change(corrections: corrections) |> Repo.update!()
    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")

    for index <- 1..4 do
      assert has_element?(view, "#flashcard-q#{index}")
      assert has_element?(view, "#flashcard-stack-overlay[phx-update=ignore][aria-hidden=true]")

      if index <= 2 do
        assert has_element?(view, "#flashcard-underlay-2[aria-hidden=true]")
      else
        refute has_element?(view, "#flashcard-underlay-2")
      end

      if index < 4 do
        assert has_element?(view, "#flashcard-underlay-1[aria-hidden=true]")
        assert has_element?(view, "#next-card[data-has-next=true]")
        view |> element("#next-card") |> render_click()
        assert_push_event(view, "flashcard:advanced", %{})
      else
        refute has_element?(view, "#flashcard-underlay-1")
        assert has_element?(view, "#next-card[data-has-next=false]")
        assert has_element?(view, "#flashcard-player[phx-remove]")
        view |> element("#next-card") |> render_click()
        assert has_element?(view, "#homework-content.flashcard-results-enter")
      end
    end
  end

  test "a single-card session has no cards underneath", %{conn: conn} do
    e = flash_exam(lesson(profile()), 1)
    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
    refute has_element?(view, ".flashcard-stack-card")
  end

  test "answers repeated in text are only displayed in the correction", %{conn: conn} do
    l = lesson(profile())

    for {type, prompt, answer, text, options} <- [
          {"definition", "Définis la Préhistoire.", "Avant l’écriture.", "  Avant l'écriture ! ",
           []},
          {"mcq", "Quelles grottes sont célèbres pour l’art pariétal ?", "Lascaux et Chauvet",
           "LASCAUX  ET CHAUVET.", ["Lascaux et Chauvet", "Versailles et Chambord"]}
        ] do
      q =
        question("q1", type)
        |> Map.merge(%{
          "prompt" => prompt,
          "answer" => answer,
          "text" => text,
          "options" => options
        })

      e = exam(l, [q]) |> Ecto.Changeset.change(format: "flashcard") |> Repo.update!()
      {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
      assert has_element?(view, "#flashcard-question", String.replace(prompt, " ?", "\u00A0?"))
      refute has_element?(view, ".flashcard-front .reading-text")
      refute has_element?(view, "#flashcard-correction")

      if type == "mcq", do: assert(has_element?(view, "#flashcard-option-0[value='#{answer}']"))

      {:ok, _} = Exams.Flashcards.submit(l.profile_id, e.id, "q1", answer, sync: true)
      send(view.pid, :refresh_exam)
      assert has_element?(view, "#flashcard-correction .expected-answer", answer)
    end
  end

  test "a generic definition heading is replaced by the actual question", %{conn: conn} do
    l = lesson(profile())

    for heading <- ["definition", "Définition :"] do
      q =
        question("q1", "definition")
        |> Map.merge(%{
          "prompt" => heading,
          "text" => "Pourquoi les premiers humains migrent-ils ?"
        })

      e = exam(l, [q]) |> Ecto.Changeset.change(format: "flashcard") |> Repo.update!()
      {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
      assert has_element?(view, "#flashcard-question", String.replace(q["text"], " ?", "\u00A0?"))
      refute has_element?(view, ".flashcard-front .reading-text")
    end
  end

  test "a meaningful prompt keeps its supporting text regardless of wording", %{conn: conn} do
    l = lesson(profile())

    for text <- ["Un extrait du cours utile.", "Écris le mot français", "Écris le mot anglais."] do
      q = question("q1", "definition") |> Map.put("text", text)

      e = exam(l, [q]) |> Ecto.Changeset.change(format: "flashcard") |> Repo.update!()

      {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
      assert has_element?(view, "#flashcard-question", q["prompt"])
      assert has_element?(view, ".flashcard-front .reading-text", text)
    end
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

    for type <- CaptainHomework.QuestionDefinitions.available(l.subject) do
      selector = "#question-type-#{type.id}"

      if "flashcard" in type.modes do
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

    assert has_element?(
             view,
             "#flashcard-response[autocomplete=off][autocorrect=off][autocapitalize=off][spellcheck=false][writingsuggestions=false]"
           )

    assert has_element?(view, ".page-shell-immersive #flashcard-player")
    assert has_element?(view, "#close-flashcards[href='/alice/lecons/#{e.lesson_id}']")

    assert has_element?(
             view,
             ".flashcard-front #flashcard-actions #validate-card[form=flashcard-answer]"
           )

    refute has_element?(view, "#child-picker")
    refute has_element?(view, "#exam-footer")
    refute has_element?(view, ".app-brand-footer")
    refute has_element?(view, "#flashcard-session [autofocus]")
    refute has_element?(view, "#flashcard-q2")
    refute has_element?(view, "#flashcard-player[phx-remove]")
    refute has_element?(view, "#exam-answers")
    refute has_element?(view, "#finish-exam")
    refute has_element?(view, "#flashcard-correction")
    view |> form("#flashcard-answer", %{"answers" => %{"q1" => "quart"}}) |> render_submit()
    await_correction(e, "q1")
    send(view.pid, :refresh_exam)
    assert has_element?(view, "#flashcard-inner.is-flipped")
    assert has_element?(view, "#flashcard-verdict.flashcard-incorrect", "Incorrect")
    assert has_element?(view, "#flashcard-verdict .flashcard-verdict-icon .icon")
    refute has_element?(view, "#flashcard-correction .student-answer")
    assert has_element?(view, "#flashcard-answer fieldset[disabled]")
    assert has_element?(view, ".flashcard-back #next-card", "Question suivante")
    {:ok, reloaded, _} = live(conn, "/alice/controles/#{e.id}")
    assert has_element?(reloaded, "#flashcard-inner.is-flipped")
    reloaded |> element("#next-card") |> render_click()
    assert has_element?(reloaded, "#flashcard-q2")
    refute has_element?(reloaded, "#flashcard-q1")
    refute has_element?(reloaded, ".is-flipped")

    reloaded
    |> form("#flashcard-answer", %{"answers" => %{"q2" => "trois quarts"}})
    |> render_submit()

    await_correction(e, "q2")
    send(reloaded.pid, :refresh_exam)
    assert has_element?(reloaded, "#flashcard-verdict.flashcard-incorrect", "Incorrect")
    assert has_element?(reloaded, "#next-card", "Voir mon résultat")
    assert has_element?(reloaded, "#flashcard-player[phx-remove]")
    refute has_element?(reloaded, ".total-score")
    reloaded |> element("#next-card") |> render_click()
    refute has_element?(reloaded, "#flashcard-session")
    refute has_element?(reloaded, ".page-shell-immersive")
    assert has_element?(reloaded, "#homework-content.flashcard-results-enter")
    assert has_element?(reloaded, "#child-picker")
    assert has_element?(reloaded, ".app-brand-footer")
    assert has_element?(reloaded, ".total-score", "10")
    assert has_element?(reloaded, "#question-q1 .correction")
    assert has_element?(reloaded, "#question-q2 .correction")
    assert has_element?(reloaded, "#exam-appreciation")
  end

  test "a fully correct answer displays the green verdict", %{conn: conn} do
    e = flash_exam(lesson(profile()))
    {:ok, _} = Exams.Flashcards.submit(profile().id, e.id, "q1", "juste", sync: true)
    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")

    assert has_element?(view, "#flashcard-verdict.flashcard-correct", "Correct")
    assert has_element?(view, "#flashcard-verdict .flashcard-verdict-icon .icon")
    assert has_element?(view, "#flashcard-correction .flashcard-feedback .expected-answer")
    refute has_element?(view, "#flashcard-correction .student-answer")
  end

  test "closing the player returns to the lesson and preserves the current answer", %{conn: conn} do
    e = flash_exam(lesson(profile()))
    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
    view |> form("#flashcard-answer") |> render_change(%{"answers" => %{"q1" => "Brouillon"}})
    view |> element("#close-flashcards") |> render_click()
    assert_redirect(view, "/alice/lecons/#{e.lesson_id}")
    {:ok, resumed, _} = live(conn, "/alice/controles/#{e.id}")
    assert has_element?(resumed, "#flashcard-response[value=Brouillon]")
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

    assert has_element?(
             view,
             "#flashcard-slot-0[autocomplete=off][autocorrect=off][autocapitalize=off][spellcheck=false][writingsuggestions=false]"
           )
  end

  defp await_correction(exam, id) do
    if Map.has_key?(Study.get_exam!(profile().id, exam.id).corrections, id) do
      :ok
    else
      assert_receive :exam_updated, 2000
      await_correction(exam, id)
    end
  end

  test "validation loads in the button and flips only after correction, recovering from errors",
       %{
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
      assert has_element?(view, "#flashcard-inner.is-grading:not(.is-flipped)")
      assert has_element?(view, "#validate-card[disabled][aria-busy=true] .spinner")
      assert has_element?(view, "#validate-card[aria-label='Correction en cours']")
      assert has_element?(view, ".flashcard-front[aria-hidden=false]")
      assert has_element?(view, "#flashcard-answer fieldset[disabled]")
      refute has_element?(view, ".flashcard-content .spinner")
      refute has_element?(view, "p.notice[role=status]")
      refute has_element?(view, "#flashcard-correction")
      refute has_element?(view, "#next-card")

      send(worker, outcome)
      assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 2000
      send(view.pid, :refresh_exam)
      refute has_element?(view, ".is-grading")

      if outcome == :fail_grading do
        refute has_element?(view, ".is-flipped")
        assert has_element?(view, "#flashcard-response[value=quart]")
        refute has_element?(view, "#flashcard-answer fieldset[disabled]")
        assert has_element?(view, "#validate-card:not([disabled])[aria-busy=false]")
      else
        assert has_element?(view, ".is-flipped #flashcard-correction")
        refute has_element?(view, "#validate-card")
        assert has_element?(view, "#next-card")
      end
    end
  end
end

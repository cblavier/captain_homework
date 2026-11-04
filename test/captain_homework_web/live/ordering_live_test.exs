defmodule CaptainHomeworkWeb.OrderingLiveTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.{AI, Exams, QuestionDefinitions, Repo, Study}

  defp ordering_question(id \\ "q1") do
    question(id, "ordering")
    |> Map.merge(%{
      "prompt" => "Classe ces événements du plus ancien au plus récent.",
      "options" => ["Naissance de l’écriture", "Maîtrise du feu", "Début de l’agriculture"],
      "answer" => "2, 3, 1",
      "rubric" => "Respecter l’ordre chronologique.",
      "points" => 1
    })
  end

  test "classic and flashcard clicks persist a unique sequence, with undo and reset", %{
    conn: conn
  } do
    l = lesson(profile())

    for format <- ["classic", "flashcard"] do
      control =
        exam(l, [ordering_question(), question("q2")])
        |> Ecto.Changeset.change(format: format)
        |> Repo.update!()

      {:ok, view, _} = live(conn, "/alice/controles/#{control.id}")
      assert has_element?(view, "#ordering-q1-undo[disabled]")
      refute has_element?(view, "#answer-q1")
      refute has_element?(view, "#flashcard-response")

      for n <- [2, 3, 3, 1], do: view |> element("#ordering-q1-choice-#{n}") |> render_click()
      assert Study.get_exam!(l.profile_id, control.id).answers["q1"] == "2, 3, 1"
      assert has_element?(view, "#ordering-q1 input[value='2, 3, 1']")
      assert has_element?(view, "#ordering-q1-choice-2[aria-pressed=true] .ordering-rank", "1")
      assert has_element?(view, "#ordering-q1-sequence", "2 → 3 → 1")

      {:ok, reloaded, _} = live(conn, "/alice/controles/#{control.id}")
      assert has_element?(reloaded, "#ordering-q1 input[value='2, 3, 1']")
      reloaded |> element("#ordering-q1-undo") |> render_click()
      assert has_element?(reloaded, "#ordering-q1 input[value='2, 3']")
      assert has_element?(reloaded, "#ordering-q1-choice-1[aria-pressed=false]")
      reloaded |> element("#ordering-q1-clear") |> render_click()
      assert Study.get_exam!(l.profile_id, control.id).answers["q1"] == ""
      assert has_element?(reloaded, "#ordering-q1-sequence", "À toi de commencer")
      render_click(reloaded, "order_answer", %{"id" => "q1", "action" => "999"})
      assert Study.get_exam!(l.profile_id, control.id).answers["q1"] == ""
    end
  end

  test "ordering preserves other answers and rejects edits to corrected or non-current cards", %{
    conn: conn
  } do
    old = Application.fetch_env!(:captain_homework, :ai_provider)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.TestAI)
    on_exit(fn -> Application.put_env(:captain_homework, :ai_provider, old) end)
    l = lesson(profile())
    control = exam(l, [ordering_question(), ordering_question("q2")])
    {:ok, _} = Study.save_answers(l.profile_id, control.id, %{"q2" => "1, 2, 3"})
    {:ok, updated} = Study.order_answer(l.profile_id, control.id, "q1", "2")
    assert updated.answers["q2"] == "1, 2, 3"

    assert_raise Ecto.NoResultsError, fn ->
      Study.order_answer(profile("Bob").id, control.id, "q1", "1")
    end

    updated |> Ecto.Changeset.change(format: "flashcard") |> Repo.update!()
    assert {:error, :unavailable} = Study.order_answer(l.profile_id, control.id, "q2", "clear")
    {:ok, _} = Exams.Flashcards.submit(l.profile_id, control.id, "q1", "2, 3, 1", sync: true)
    assert {:error, :unavailable} = Study.order_answer(l.profile_id, control.id, "q1", "clear")
    assert Study.get_exam!(l.profile_id, control.id).answers["q1"] == "2, 3, 1"
    {:ok, view, _} = live(conn, "/alice/controles/#{control.id}")
    assert has_element?(view, "#flashcard-inner.is-flipped")
    assert has_element?(view, "#ordering-q1-choice-1[disabled]")
    assert has_element?(view, "#flashcard-correction .expected-answer", "2, 3, 1")
    view |> element("#next-card") |> render_click()
    assert has_element?(view, "#ordering-q2")
    refute has_element?(view, "#ordering-q1")
  end

  test "submitting either form sends the clicked sequence to correction", %{conn: conn} do
    old = Application.fetch_env!(:captain_homework, :ai_provider)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.TestAI)
    on_exit(fn -> Application.put_env(:captain_homework, :ai_provider, old) end)
    l = lesson(profile())

    for format <- ["classic", "flashcard"] do
      control =
        exam(l, [ordering_question()]) |> Ecto.Changeset.change(format: format) |> Repo.update!()

      Phoenix.PubSub.subscribe(CaptainHomework.PubSub, "exam:#{control.id}")
      {:ok, view, _} = live(conn, "/alice/controles/#{control.id}")
      for n <- [2, 3, 1], do: view |> element("#ordering-q1-choice-#{n}") |> render_click()

      if format == "classic" do
        view |> form("#exam-answers") |> render_submit()
        assert has_element?(view, "#submit-confirm", "1 réponses sur 1")
        view |> element("#confirm-finish") |> render_click()
      else
        view |> form("#flashcard-answer") |> render_submit()
      end

      corrected = await_correction(l.profile_id, control.id)
      assert corrected.answers["q1"] == "2, 3, 1"
      assert corrected.corrections["q1"]["expected"] == "2, 3, 1"
      assert {:error, :unavailable} = Study.order_answer(l.profile_id, control.id, "q1", "clear")
      Phoenix.PubSub.unsubscribe(CaptainHomework.PubSub, "exam:#{control.id}")
    end
  end

  defp await_correction(profile_id, exam_id) do
    exam = Study.get_exam!(profile_id, exam_id)

    if Map.has_key?(exam.corrections, "q1") do
      exam
    else
      assert_receive :exam_updated, 2000
      await_correction(profile_id, exam_id)
    end
  end

  test "the shared preview works in both modes and resets when its events change", %{conn: conn} do
    {:ok, _} = QuestionDefinitions.seed!()
    type = Enum.find(QuestionDefinitions.list(), &(&1.name == "Classement chronologique"))
    assert type.response_kind == "ordering"
    assert QuestionDefinitions.mode_allowed?(type, "flashcard")
    assert QuestionDefinitions.generation_supported?(type)
    assert QuestionDefinitions.formats([type]) == ["ordering"]
    {:ok, view, _} = live(conn, "/alice/parametres/types/#{type.id}")

    for mode <- ["classic", "flashcard"] do
      view |> form("#type-preview-mode") |> render_change(%{"mode" => mode})

      if has_element?(view, "#preview-ordering-clear:not([disabled])"),
        do: view |> element("#preview-ordering-clear") |> render_click()

      view |> element("#preview-ordering-choice-2") |> render_click()
      assert has_element?(view, "#preview-ordering input[value='2']")
      assert has_element?(view, "#preview-ordering-choice-2", "Maîtrise du feu")
      refute has_element?(view, "#preview-answer")
      refute has_element?(view, "#preview-support")
    end

    view
    |> form("#type-example")
    |> render_change(%{"example" => %{"text" => "1. Premier événement\n2. Autre événement"}})

    assert has_element?(view, "#preview-ordering input[value='']")
    refute has_element?(view, "#preview-ordering-choice-3")
  end

  test "only quick supported types start checked and manually selected intermediate types survive format changes",
       %{conn: conn} do
    {:ok, _} = QuestionDefinitions.seed!()
    l = lesson(profile(), "histoire-geo")
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}/controle")
    assert has_element?(view, "#question-types-quick input[checked]")
    refute has_element?(view, "#question-types-medium input[checked]")
    refute has_element?(view, "#question-types-long input[checked]")
    type = Enum.find(QuestionDefinitions.list(), &(&1.name == "Classement chronologique"))
    view |> form("#exam-setup") |> render_change(%{"question_types" => [type.id]})
    assert has_element?(view, "#question-type-#{type.id}[checked]")
    view |> form("#exam-setup") |> render_change(%{"format" => "flashcard"})
    assert has_element?(view, "#question-type-#{type.id}[checked]:not([disabled])")
    view |> form("#exam-setup") |> render_change(%{"format" => "classic"})
    assert has_element?(view, "#question-type-#{type.id}[checked]:not([disabled])")
  end

  test "generated ordering questions require a full permutation and sanitize student input" do
    q = ordering_question()
    assert AI.question_errors(q) == []

    for answer <- ["2, 2, 1", "2, 1", "2, 3, 4", "2, 3, 1, 1", "Inventé"],
        do: assert(AI.question_errors(Map.put(q, "answer", answer)) != [])

    assert AI.question_errors(Map.put(q, "options", ["Identique", "Identique"])) != []
    control = exam(lesson(profile()), [q])
    assert Study.sanitize_answers(control, %{"q1" => "2, 2, 42, 1"}) == %{"q1" => "2, 1"}
    assert Exams.Constraints.effort_supported?("ordering", "direct")
  end
end

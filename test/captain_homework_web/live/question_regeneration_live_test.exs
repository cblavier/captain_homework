defmodule CaptainHomeworkWeb.QuestionRegenerationLiveTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Auth, Repo, Study}
  alias CaptainHomework.Exams.QuestionRegeneration

  setup do
    p = profile()
    l = lesson(p)
    page(l)

    e =
      exam(l, [
        question("first"),
        question("target") |> Map.put("prompt", "Explique le rôle du noyau.")
      ])

    old = Application.fetch_env!(:captain_homework, :ai_provider)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.BlockingGenerationAI)
    Application.put_env(:captain_homework, :generation_test_pid, self())

    on_exit(fn ->
      Application.put_env(:captain_homework, :ai_provider, old)
      Application.delete_env(:captain_homework, :generation_test_pid)
    end)

    %{exam: e, types: question_type_ids(["long"])}
  end

  test "parent opens the shared type picker and sees persistent generation at the question location",
       %{conn: conn, exam: e, types: types} do
    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
    view |> element("#regenerate-question-target") |> render_click()
    assert has_element?(view, "#regenerate-question-modal")
    assert has_element?(view, "#replacement-types input[type=checkbox]")

    view
    |> form("#regenerate-question-form", %{
      "question_types" => types,
      "instructions" => "Une question différente"
    })
    |> render_submit()

    assert_push_event view, "question-regeneration-started", %{id: "target"}

    assert Study.get_exam!(profile().id, e.id).regeneration["instructions"] ==
             "Une question différente"

    assert_receive {:generation_waiting, worker, []}, 2000
    on_exit(fn -> Process.exit(worker, :kill) end)
    ref = Process.monitor(worker)
    refute has_element?(view, "#regenerate-question-modal")
    assert has_element?(view, "#question-target #replacement-progress-target")
    assert has_element?(view, "#question-target .generation-question-copy strong", "Question 2")
    assert has_element?(view, "#question-first textarea")
    assert has_element?(view, "#finish-exam[disabled]")
    refute has_element?(view, "#question-target textarea")

    {:ok, reopened, _} = live(conn, "/alice/controles/#{e.id}")
    assert has_element?(reopened, "#question-target #replacement-progress-target")

    assert has_element?(
             reopened,
             "#question-target .generation-question-copy strong",
             "Question 2"
           )

    assert has_element?(reopened, "#replacement-generation-questions-target details")
    assert {:error, _} = CaptainHomework.Exams.submit(profile().id, e.id, %{}, sync: true)

    new =
      question("fresh")
      |> Map.put("prompt", "Combien de pattes a une araignée ?")
      |> Map.put("answer", "Huit")

    send(worker, {:generation_reply, {:ok, [new]}})
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 2000
    send(view.pid, :exam_updated)
    refute has_element?(view, "#replacement-progress-target")
    assert has_element?(view, "#question-first")

    assert Study.get_exam!(profile().id, e.id).regeneration["instructions"] ==
             "Une question différente"

    [_, replacement] = Study.get_exam!(profile().id, e.id).questions
    assert has_element?(view, "#question-#{replacement["id"]}")
    refute has_element?(view, "#finish-exam[disabled]")
  end

  test "two replacements run together and finish independently in reverse order", %{
    conn: conn,
    exam: e,
    types: types
  } do
    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")

    workers =
      for id <- ["first", "target"] do
        view |> element("#regenerate-question-#{id}") |> render_click()
        view |> form("#regenerate-question-form", %{"question_types" => types}) |> render_submit()
        assert_receive {:generation_waiting, worker, []}, 2000
        on_exit(fn -> Process.exit(worker, :kill) end)
        {id, worker, Process.monitor(worker)}
      end

    assert has_element?(view, "#question-first #replacement-progress-first")
    assert has_element?(view, "#question-target #replacement-progress-target")
    assert has_element?(view, "#question-first .generation-question-copy strong", "Question 1")
    assert has_element?(view, "#question-target .generation-question-copy strong", "Question 2")
    {:ok, reopened, _} = live(conn, "/alice/controles/#{e.id}")
    assert has_element?(reopened, "#replacement-progress-first")
    assert has_element?(reopened, "#replacement-progress-target")

    assert {:ok, saved} =
             Study.save_answers(profile().id, e.id, %{"first" => "ignored", "target" => "ignored"})

    assert saved.answers["first"] == nil
    assert saved.answers["target"] == nil

    [{"target", second, second_ref}, {"first", first, first_ref}] = Enum.reverse(workers)

    replacement =
      question("new-target")
      |> Map.put("prompt", "Combien de pattes a une araignée ?")
      |> Map.put("answer", "Huit")

    send(second, {:generation_reply, {:ok, [replacement]}})
    assert_receive {:DOWN, ^second_ref, :process, ^second, :normal}, 2000
    send(view.pid, :exam_updated)
    assert has_element?(view, "#replacement-progress-first")
    refute has_element?(view, "#replacement-progress-target")
    assert has_element?(view, "#finish-exam[disabled]")

    replacement =
      question("new-first")
      |> Map.put("prompt", "Combien de pattes a un chat ?")
      |> Map.put("answer", "Quatre")

    send(first, {:generation_reply, {:ok, [replacement]}})
    assert_receive {:DOWN, ^first_ref, :process, ^first, :normal}, 2000
    send(view.pid, :exam_updated)
    refute has_element?(view, ".replacement-progress")
    refute has_element?(view, "#finish-exam[disabled]")
    result = Study.get_exam!(profile().id, e.id)

    assert Enum.map(result.questions, & &1["prompt"]) == [
             "Combien de pattes a un chat ?",
             "Combien de pattes a une araignée ?"
           ]

    refute QuestionRegeneration.pending?(result)
  end

  test "instructions persist across questions and reloads only within the same exam", %{
    conn: conn,
    exam: e
  } do
    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
    view |> element("#regenerate-question-first") |> render_click()

    view
    |> form("#regenerate-question-form", %{"instructions" => "Privilégier les exemples concrets."})
    |> render_change()

    view
    |> element("#regenerate-question-modal button.secondary[phx-click=close_modal]")
    |> render_click()

    view |> element("#regenerate-question-target") |> render_click()

    assert has_element?(
             view,
             "#replacement-instructions[phx-debounce=blur][autocomplete=off][autocorrect=on][spellcheck=true][writingsuggestions=true]",
             "Privilégier les exemples concrets."
           )

    {:ok, reopened, _} = live(conn, "/alice/controles/#{e.id}")
    reopened |> element("#regenerate-question-first") |> render_click()

    assert has_element?(
             reopened,
             "#replacement-instructions",
             "Privilégier les exemples concrets."
           )

    other = exam(Study.get_lesson!(profile().id, e.lesson_id), [question("different")])
    {:ok, other_view, _} = live(conn, "/alice/controles/#{other.id}")
    other_view |> element("#regenerate-question-different") |> render_click()

    refute has_element?(
             other_view,
             "#replacement-instructions",
             "Privilégier les exemples concrets."
           )

    reopened |> form("#regenerate-question-form", %{"instructions" => ""}) |> render_change()
    {:ok, cleared, _} = live(conn, "/alice/controles/#{e.id}")
    cleared |> element("#regenerate-question-target") |> render_click()
    assert has_element?(cleared, "#replacement-instructions")
    assert Study.get_exam!(profile().id, e.id).regeneration["instructions"] == ""
  end

  test "failed replacement hides the old question until a parent explicitly cancels", %{
    conn: conn,
    exam: e
  } do
    job =
      %Study.Exam{
        lesson_id: e.lesson_id,
        regeneration_source_id: e.id,
        instructions: "",
        status: "generation_partial",
        generation_target: 1
      }
      |> CaptainHomework.Exams.GenerationHistory.initialize()
      |> CaptainHomework.Exams.GenerationHistory.stopped("Échec de génération")
      |> Repo.insert!()

    e
    |> Ecto.Changeset.change(
      regeneration: %{"job_id" => job.id, "question_id" => "target", "status" => "failed"},
      answers: %{"target" => "Réponse conservée"}
    )
    |> Repo.update!()

    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
    assert has_element?(view, "#question-target #replacement-progress-target")
    refute has_element?(view, "#question-target textarea")
    assert has_element?(view, "#finish-exam[disabled]")
    assert {:error, _} = CaptainHomework.Exams.submit(profile().id, e.id, %{}, sync: true)

    assert {:error, _} =
             QuestionRegeneration.cancel(
               CaptainHomework.Accounts.get("child-1"),
               profile().id,
               e.id,
               job.id
             )

    view |> element("#question-target .cancel-regeneration") |> render_click()
    refute has_element?(view, "#replacement-progress-target")
    assert has_element?(view, "#question-target textarea", "Réponse conservée")
    refute has_element?(view, "#finish-exam[disabled]")
    {:ok, reopened, _} = live(conn, "/alice/controles/#{e.id}")
    refute has_element?(reopened, "#replacement-progress-target")
    assert Repo.get!(Study.Exam, job.id).status == "generation_partial"
  end

  test "children and family cannot open the modal or forge regeneration events", %{
    exam: e,
    types: types
  } do
    for account <- ~w(child-1 family) do
      conn = build_conn() |> init_test_session(Auth.session(account))
      {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
      refute has_element?(view, "#regenerate-question-target")
      render_click(view, "open_regeneration", %{"id" => "target"})
      render_submit(view, "regenerate_question", %{"question_types" => types})
      refute has_element?(view, "#regenerate-question-modal")
      refute QuestionRegeneration.running?(Repo.get!(Study.Exam, e.id))
    end
  end
end

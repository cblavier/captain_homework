defmodule CaptainHomeworkWeb.GenerationHistoryLiveTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.{AI, DetailedGenerationAI, Exams, ExamShares, Repo}

  setup do
    previous = AI.provider()
    Application.put_env(:captain_homework, :ai_provider, DetailedGenerationAI)
    on_exit(fn -> Application.put_env(:captain_homework, :ai_provider, previous) end)

    start_supervised!(%{
      id: DetailedGenerationAI,
      start:
        {Agent, :start_link,
         [
           fn ->
             %{
               calls: [],
               audits: [
                 {:reject,
                  %{
                    "q2" => %{
                      "reason" => "La consigne demande trop d’éléments.",
                      "issue_codes" => ["content"]
                    }
                  }},
                 :ok
               ],
               content_repairs: [{:change_prompt, "Consigne corrigée"}]
             }
           end,
           [name: DetailedGenerationAI]
         ]}
    })

    lesson = lesson(profile())
    page(lesson)
    {:ok, exam} = Exams.generate(lesson.profile_id, lesson.id, 2, "")
    %{exam: exam}
  end

  test "completed generation exposes stable rows, rejection history and before/after", %{
    conn: conn,
    exam: exam
  } do
    {:ok, view, _} = live(conn, "/alice/controles/#{exam.id}")
    refute has_element?(view, "#generation-status")
    refute has_element?(view, "#generation-history-modal")
    view |> element("#generation-duration") |> render_click()
    assert has_element?(view, "#generation-history-modal")
    assert has_element?(view, "#generation-question-1[data-status=ready]")

    assert has_element?(
             view,
             "#generation-question-2 .generation-question-badge",
             "Prête · corrigée"
           )

    assert has_element?(
             view,
             "#generation-question-2-events [data-status=rejected]",
             "La consigne demande trop d’éléments."
           )

    assert has_element?(
             view,
             "#generation-question-2-version-2 .generation-comparison",
             "Question 2"
           )

    assert has_element?(
             view,
             "#generation-question-2-version-2 .generation-comparison",
             "Consigne corrigée"
           )

    refute has_element?(view, "#generation-question-2", "Réponse 2")
    assert has_element?(view, "#generation-question-2[phx-mounted]")
    assert has_element?(view, "#exam-answers")
    send(view.pid, :exam_updated)
    assert has_element?(view, "#generation-question-2[data-status=ready]")
    {:ok, reloaded, _} = live(conn, "/alice/controles/#{exam.id}")
    refute has_element?(reloaded, "#generation-question-2")
    reloaded |> element("#generation-duration") |> render_click()
    assert has_element?(reloaded, "#generation-question-2-events [data-status=rejected]")
    render_click(reloaded, "close_modal")
    refute has_element?(reloaded, "#generation-history-modal")
    reloaded |> element("#generation-duration") |> render_click()
    assert has_element?(reloaded, "#generation-question-2")
  end

  test "flashcard history can be reopened without losing its streamed questions", %{
    conn: conn,
    exam: exam
  } do
    exam = Repo.update!(Ecto.Changeset.change(exam, format: "flashcard"))
    {:ok, view, _} = live(conn, "/alice/controles/#{exam.id}")
    assert has_element?(view, "#flashcard-player")
    view |> element("#generation-duration") |> render_click()
    assert has_element?(view, "#generation-history-modal #generation-question-2")
    render_click(view, "close_modal")
    refute has_element?(view, "#generation-history-modal")
    view |> element("#generation-duration") |> render_click()
    assert has_element?(view, "#generation-history-modal #generation-question-1")
  end

  test "shared correction does not expose generation drafts or diagnostics", %{
    conn: conn,
    exam: exam
  } do
    corrections =
      Map.new(exam.questions, fn q ->
        {q["id"],
         %{
           "points" => q["points"],
           "fraction" => 1.0,
           "expected" => q["answer"],
           "feedback" => "Correct"
         }}
      end)

    completed =
      Repo.update!(
        Ecto.Changeset.change(exam, status: "completed", score: 20.0, corrections: corrections)
      )

    {:ok, _share, token} =
      ExamShares.create(profile().id, completed.id, "correction")

    {:ok, view, _} = live(conn, "/partage/#{token}")
    refute has_element?(view, "#generation-history")
    refute has_element?(view, "#generation-questions")
    refute has_element?(view, "#generation-duration")
  end
end

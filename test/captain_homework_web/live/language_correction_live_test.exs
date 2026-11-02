defmodule CaptainHomeworkWeb.LanguageCorrectionLiveTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Exams, Repo}

  test "language errors are interactive without changing the grade or original answer", %{
    conn: conn
  } do
    e =
      exam(lesson(profile()))
      |> Ecto.Changeset.change(answers: %{"q1" => "Les chat jouent."})
      |> Repo.update!()

    annotation = %{
      "field" => "",
      "original" => "chat",
      "replacement" => "chats",
      "occurrence" => 1,
      "explanation" => "Le déterminant « les » impose le pluriel : chats."
    }

    {:ok, corrections, score} =
      Exams.validate_grades(e, [
        %{
          "id" => "q1",
          "fraction" => 1,
          "feedback" => "Correct.",
          "language_errors" => [annotation]
        }
      ])

    assert score == 20.0

    e
    |> Ecto.Changeset.change(status: "completed", corrections: corrections, score: score)
    |> Repo.update!()

    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
    refute has_element?(view, "fieldset[disabled] .language-error")
    assert has_element?(view, "#student-answer-q1 .language-error del", "chat")
    assert has_element?(view, "#student-answer-q1 .language-replacement", "chats")
    view |> element("#student-answer-q1 .language-error") |> render_click()
    assert has_element?(view, "#language-error-modal[role='dialog']")
    assert has_element?(view, "#language-error-explanation", "impose le pluriel")
    view |> element("#language-error-modal button[phx-click='close_modal']") |> render_click()
    refute has_element?(view, "#language-error-modal")
    assert Repo.reload!(e).answers == %{"q1" => "Les chat jouent."}
  end

  test "QCM wording is never corrected as a student's language mistake" do
    q = question("q1", "mcq")

    e =
      exam(lesson(profile()), [q])
      |> Ecto.Changeset.change(answers: %{"q1" => q["answer"]})
      |> Repo.update!()

    {:ok, corrections, _} =
      Exams.validate_grades(e, [
        %{
          "id" => "q1",
          "fraction" => 1,
          "feedback" => "Correct.",
          "language_errors" => [
            %{
              "field" => "",
              "original" => "Elle",
              "replacement" => "Il",
              "occurrence" => 1,
              "explanation" => "Ne doit pas apparaître."
            }
          ]
        }
      ])

    assert corrections["q1"]["language_errors"] == []
  end
end

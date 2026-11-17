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
    view |> element("#contest-correction-q1") |> render_click()
    assert has_element?(view, "#contest-correction-modal[role='dialog']")
    assert has_element?(view, "#contestation-form textarea[name='contestation[explanation]']")
    refute has_element?(view, "#contestation-form textarea[required]")
    assert has_element?(view, "#submit-contestation")
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

  test "a punctuation insertion does not strike through the unchanged clause", %{conn: conn} do
    answer = "une ville où les habitants partent où on manque d'emplois"
    original = "partent où on manque d'emplois"

    annotation = %{
      "field" => "",
      "original" => original,
      "replacement" => "partent, où on manque d'emplois",
      "occurrence" => 1,
      "explanation" => "Une virgule sépare les deux propositions relatives liées à « ville »."
    }

    e = completed_exam(answer, [annotation])
    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")

    assert has_element?(view, "#student-answer-q1 .language-replacement", ",")
    refute has_element?(view, "#student-answer-q1 del")

    assert view
           |> element("#student-answer-q1 .language-error")
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.text() == ","

    view |> element("#student-answer-q1 .language-error") |> render_click()
    assert has_element?(view, "#language-error-explanation", "propositions relatives")
    assert Repo.reload!(e).answers == %{"q1" => answer}
    assert Repo.reload!(e).score == 20.0
  end

  test "saved duplicates are hidden while other explanations still open correctly", %{conn: conn} do
    answer = "être coupé des flux mondiau"

    annotation = %{
      "field" => "",
      "original" => "mondiau",
      "replacement" => "mondiaux",
      "occurrence" => 1,
      "explanation" => "Le pluriel est « mondiaux »."
    }

    e = completed_exam(answer, [annotation])

    old_error = %{
      "field" => "",
      "original" => "être",
      "replacement" => "être coupé",
      "start" => 0,
      "length" => 5,
      "explanation" => "Ancienne correction incorrecte."
    }

    corrections = update_in(e.corrections, ["q1", "language_errors"], &[old_error | &1])
    e = e |> Ecto.Changeset.change(corrections: corrections) |> Repo.update!()
    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")

    refute has_element?(view, "#student-answer-q1 .language-error del", "être")
    assert has_element?(view, "#student-answer-q1 .language-error[phx-value-index='1']")
    view |> element("#student-answer-q1 .language-error") |> render_click()
    assert has_element?(view, "#language-error-explanation", "Le pluriel est")
    assert Repo.reload!(e).corrections == corrections
    assert Repo.reload!(e).answers == %{"q1" => answer}
  end

  defp completed_exam(answer, annotations) do
    e =
      exam(lesson(profile()))
      |> Ecto.Changeset.change(answers: %{"q1" => answer})
      |> Repo.update!()

    {:ok, corrections, score} =
      Exams.validate_grades(e, [
        %{
          "id" => "q1",
          "fraction" => 1,
          "feedback" => "Correct.",
          "language_errors" => annotations
        }
      ])

    e
    |> Ecto.Changeset.change(status: "completed", corrections: corrections, score: score)
    |> Repo.update!()
  end
end

defmodule CaptainHomeworkWeb.ClozeInlineLiveTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Repo, Study}
  alias CaptainHomeworkWeb.QuestionComponents

  defp cloze do
    question("holes", "cloze")
    |> Map.merge(%{
      "text" => "The dead could {{1}} {{2}} on that day.",
      "slots" => ["1", "2"]
    })
  end

  test "inline fields save independently and survive reopening", %{conn: conn} do
    p = profile()
    control = exam(lesson(p), [cloze()])
    {:ok, view, _} = live(conn, "/alice/controles/#{control.id}")
    assert has_element?(view, "#answer-holes-passage .cloze-field", "1")
    assert has_element?(view, "#answer-holes-1[placeholder='…']")
    refute has_element?(view, "#question-holes .question-content .reading-text")
    refute has_element?(view, "#question-holes .slot-inputs")

    view
    |> form("#exam-answers", %{"answers" => %{"holes" => %{"1" => "come", "2" => "back"}}})
    |> render_change()

    assert Study.get_exam!(p.id, control.id).answers["holes"] == %{"1" => "come", "2" => "back"}
    {:ok, reopened, _} = live(conn, "/alice/controles/#{control.id}")
    assert has_element?(reopened, "#answer-holes-1[value=come]")
    assert has_element?(reopened, "#answer-holes-2[value=back]")

    control |> Ecto.Changeset.change(format: "flashcard") |> Repo.update!()
    {:ok, flashcard, _} = live(conn, "/alice/controles/#{control.id}")
    assert has_element?(flashcard, "#flashcard-response-passage #flashcard-slot-0[value=come]")
  end

  test "preview uses the same inline controls and preserves punctuation and safe text" do
    html =
      render_component(&QuestionComponents.question_response/1,
        question: Map.put(cloze(), "text", "<b>{{1}}</b>,{{2}}!"),
        mode: "classic",
        preview: true,
        value: %{"1" => "hello"},
        disabled: true
      )

    doc = LazyHTML.from_fragment(html)
    assert LazyHTML.query(doc, "#preview-slot-1[value=hello][disabled]") |> Enum.count() == 1
    assert LazyHTML.query(doc, ".cloze-passage b") |> Enum.empty?()
    assert LazyHTML.text(LazyHTML.query(doc, ".cloze-passage")) =~ "<b>"
  end

  test "legacy questions without matching markers keep all answer fields" do
    html =
      render_component(&QuestionComponents.question_response/1,
        question: Map.put(cloze(), "text", "An older sentence without markers."),
        mode: "classic"
      )

    doc = LazyHTML.from_fragment(html)
    assert LazyHTML.query(doc, ".slot-inputs input") |> Enum.count() == 2
  end
end

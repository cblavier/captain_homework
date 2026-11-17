defmodule CaptainHomeworkWeb.FieldHintTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomeworkWeb.CoreComponents
  alias CaptainHomework.QuestionDefinitions

  test "input keeps its hint in the field and appends its accessible description" do
    html =
      render_component(&CoreComponents.input/1,
        id: "message",
        name: "message",
        type: "textarea",
        label: "Message",
        hint: "Quelques mots suffisent.",
        "aria-describedby": "context"
      )
      |> LazyHTML.from_fragment()

    assert LazyHTML.query(
             html,
             ".form-field > textarea[aria-describedby='context message-hint']"
           )
           |> Enum.count() == 1

    assert LazyHTML.query(html, ".form-field > textarea + #message-hint.form-field-hint")
           |> Enum.count() == 1
  end

  test "unwrapped controls preserve an explicit hint id without duplicating descriptions" do
    html =
      render_component(&CoreComponents.input/1,
        id: "source",
        name: "source",
        wrapper: false,
        hint: "Un lien public.",
        hint_id: "source-help",
        "aria-describedby": "source-help source-error"
      )
      |> LazyHTML.from_fragment()

    assert Enum.empty?(LazyHTML.query(html, ".form-field"))

    assert Enum.count(
             LazyHTML.query(
               html,
               "input[aria-describedby='source-help source-error'] + #source-help.form-field-hint"
             )
           ) == 1
  end

  test "inputs without hints keep existing descriptions" do
    html =
      render_component(&CoreComponents.input/1,
        id: "name",
        name: "name",
        "aria-describedby": "existing"
      )
      |> LazyHTML.from_fragment()

    assert Enum.count(LazyHTML.query(html, "input[aria-describedby='existing']")) == 1
    assert Enum.empty?(LazyHTML.query(html, ".form-field-hint"))
  end

  test "type editor attaches shared hints to the last example field and dynamic choices", %{
    conn: conn
  } do
    profile()
    {:ok, _} = QuestionDefinitions.seed!()
    type = Enum.find(QuestionDefinitions.list(), &(&1.name == "Analyse de document"))
    {:ok, view, _} = live(conn, "/alice/parametres/types/#{type.id}")
    assert has_element?(view, "#example_document[aria-describedby='example_document-hint']")
    assert has_element?(view, "#example_document + #example_document-hint.form-field-hint")
    refute has_element?(view, "#example_prompt-hint")

    assert has_element?(
             view,
             "input[name='type[instruction_kind]'][aria-describedby='type-instruction-hint']"
           )

    assert has_element?(view, ".settings-choices + #type-instruction-hint.form-field-hint")

    view |> form("#type-editor", type: %{content_presence: "none"}) |> render_change()
    assert has_element?(view, "#example_prompt + #example_prompt-hint.form-field-hint")
    refute has_element?(view, "#example_document-hint")

    view |> form("#type-editor", type: %{instruction_kind: "fixed"}) |> render_change()
    refute has_element?(view, "#type-instruction-hint")
    refute has_element?(view, "input[aria-describedby='type-instruction-hint']")
  end
end

defmodule CaptainHomeworkWeb.TypeAIInstructionsTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias CaptainHomework.QuestionDefinitions

  test "type instructions can be saved, reopened and cleared from the last field", %{conn: conn} do
    {:ok, _} = QuestionDefinitions.seed!()
    type = Enum.find(QuestionDefinitions.list(), &(&1.name == "Analyse de document"))
    path = "/alice/parametres/types/#{type.id}"
    {:ok, view, _} = live(conn, path)

    assert has_element?(
             view,
             "#type-editor .form-fields > .form-field:last-child > #type_ai_instructions"
           )

    refute has_element?(view, "#type_ai_instructions[required]")

    assert has_element?(
             view,
             "#type_ai_instructions + #type_ai_instructions-hint.form-field-hint"
           )

    instructions = "Demande de citer au moins deux indices précis du document."
    view |> form("#type-editor", type: %{ai_instructions: instructions}) |> render_submit()
    assert QuestionDefinitions.get!(type.id).ai_instructions == instructions

    {:ok, view, _} = live(conn, path)
    assert has_element?(view, "#type_ai_instructions", instructions)
    view |> form("#type-editor", type: %{ai_instructions: ""}) |> render_submit()
    assert is_nil(QuestionDefinitions.get!(type.id).ai_instructions)
  end
end

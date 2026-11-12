defmodule CaptainHomeworkWeb.QuestionTemplatesLiveTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.{QuestionDefinitions, Study}

  test "type names resolve for previews and pickers without changing the stored template" do
    type = %Study.QuestionDefinition{
      id: Ecto.UUID.generate(),
      name: "Traduction en {langue}",
      subjects: ["anglais", "espagnol", "francais"],
      modes: ["classic"],
      response_kind: "short_text",
      content_kind: "text",
      content_presence: "required",
      instruction_kind: "fixed",
      instruction: "Traduis en {langue}",
      example: %{"text" => "Bonjour"}
    }

    for {subject, language} <- [
          {"anglais", "anglais"},
          {"espagnol", "espagnol"},
          {"francais", "français"}
        ] do
      preview =
        render_component(&CaptainHomeworkWeb.QuestionTypeComponents.question_preview/1,
          type: type,
          mode: "classic",
          example: %{},
          subject: subject
        )

      assert preview
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(".question-type-label")
             |> LazyHTML.text()
             |> String.trim() == "Traduction en #{language}"

      picker =
        render_component(&CaptainHomeworkWeb.QuestionTypePicker.question_type_picker/1,
          types: [type],
          groups: [{"quick", "Rapides", [type]}],
          selected: [type.id],
          mode: "classic",
          subject: subject
        )

      assert picker
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(".subject-checkbox span")
             |> LazyHTML.text()
             |> String.trim() == "Traduction en #{language}"
    end

    assert type.name == "Traduction en {langue}"
  end

  test "one template previews each language without help configuration", %{
    conn: conn
  } do
    profile()

    {:ok, type} =
      QuestionDefinitions.save(%Study.QuestionDefinition{}, %{
        name: "Question multilingue",
        subjects: ["anglais", "espagnol"],
        modes: ["classic", "flashcard"],
        response_kind: "short_text",
        instruction_kind: "fixed",
        instruction: "Lis en {langue}.",
        content_kind: "text",
        content_presence: "optional",
        work_duration: "quick"
      })

    {:ok, view, _} = live(conn, "/alice/parametres/types/#{type.id}")
    refute has_element?(view, "#type-tab-aides")
    refute has_element?(view, "[name='type[help_classic]']")
    refute has_element?(view, "[name='type[help_flashcard]']")
    assert has_element?(view, "#question-type-preview .flashcard-prompt", "Lis en anglais.")
    view |> form("#type-example", example: %{text: "Texte en {langue}."}) |> render_change()
    view |> form("#type-preview-subject", subject: "espagnol") |> render_change()
    assert has_element?(view, "#question-type-preview .flashcard-prompt", "Lis en espagnol.")
    assert has_element?(view, "#question-type-preview .reading-text", "Texte en espagnol.")
    view |> form("#type-preview-mode", mode: "classic") |> render_change()
    view |> form("#type-editor", type: %{subjects: ["histoire-geo"]}) |> render_change()
    refute has_element?(view, "#type-preview-subject")

    view
    |> form("#type-editor", type: %{subjects: ["histoire-geo", "espagnol"]})
    |> render_change()

    assert has_element?(view, "#type-preview-subject option[value=espagnol][selected]")
    refute has_element?(view, "#type-preview-subject option[value=histoire-geo]")
    assert QuestionDefinitions.get!(type.id).instruction == "Lis en {langue}."
    assert QuestionDefinitions.instructions([type], "espagnol") =~ "Lis en espagnol."
    render_change(view, "preview_subject", %{"subject" => "latin"})
  end

  test "edited examples are saved and reopened without inheriting a hidden static instruction", %{
    conn: conn
  } do
    profile()

    {:ok, type} =
      QuestionDefinitions.save(%Study.QuestionDefinition{}, %{
        name: "Exemple dynamique",
        subjects: ["svt"],
        modes: ["classic"],
        response_kind: "short_text",
        instruction_kind: "dynamic",
        instruction: "HIDDEN_STATIC",
        content_kind: "document",
        content_presence: "required"
      })

    {:ok, view, _} = live(conn, "/alice/parametres/types/#{type.id}")
    assert has_element?(view, "#type-example textarea[name='example[prompt]']", "")
    refute has_element?(view, "#type-example textarea", "HIDDEN_STATIC")

    view
    |> form("#type-example",
      example: %{prompt: "Explique ce document.", document: "Un texte de démonstration."}
    )
    |> render_change()

    view |> form("#type-editor") |> render_submit()
    saved = QuestionDefinitions.get!(type.id)
    assert saved.example["prompt"] == "Explique ce document."
    assert saved.example["document"] == "Un texte de démonstration."
    assert saved.instruction == "HIDDEN_STATIC"
    {:ok, reopened, _} = live(conn, "/alice/parametres/types/#{type.id}")

    assert has_element?(
             reopened,
             "#type-example textarea[name='example[prompt]']",
             "Explique ce document."
           )

    assert has_element?(
             reopened,
             "#type-example textarea[name='example[document]']",
             "Un texte de démonstration."
           )
  end
end

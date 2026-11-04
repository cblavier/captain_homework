defmodule CaptainHomeworkWeb.QuestionTemplatesLiveTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.{QuestionDefinitions, Study}

  test "one template previews each language in instructions, content and both help modes", %{
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
        work_duration: "quick",
        help_classic: "Rédige en {langue}.",
        help_flashcard: "Réponds en {langue}."
      })

    {:ok, view, _} = live(conn, "/alice/parametres/types/#{type.id}")
    assert has_element?(view, "#question-type-preview .flashcard-prompt", "Lis en anglais.")
    assert has_element?(view, "#question-type-preview .preview-help", "Réponds en anglais.")
    view |> form("#type-example", example: %{text: "Texte en {langue}."}) |> render_change()
    view |> form("#type-preview-subject", subject: "espagnol") |> render_change()
    assert has_element?(view, "#question-type-preview .flashcard-prompt", "Lis en espagnol.")
    assert has_element?(view, "#question-type-preview .reading-text", "Texte en espagnol.")
    assert has_element?(view, "#question-type-preview .preview-help", "Réponds en espagnol.")
    view |> form("#type-preview-mode", mode: "classic") |> render_change()
    assert has_element?(view, "#question-type-preview .preview-help", "Rédige en espagnol.")
    assert QuestionDefinitions.get!(type.id).instruction == "Lis en {langue}."
    assert QuestionDefinitions.instructions([type], "espagnol") =~ "Lis en espagnol."
    render_change(view, "preview_subject", %{"subject" => "latin"})
    assert has_element?(view, "#question-type-preview .preview-help", "Rédige en espagnol.")
  end
end

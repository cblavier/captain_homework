defmodule CaptainHomeworkWeb.SubjectSettingsLiveTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.{QuestionDefinitions, Repo, Study}

  test "settings entry is icon only, and subject preferences are scoped to the selected child", %{
    conn: conn
  } do
    profile()
    {:ok, home, _} = live(conn, "/alice")

    assert has_element?(
             home,
             "#subjects-settings-button[href='/alice/matieres/parametres'][aria-label='Paramètres'] svg"
           )

    assert has_element?(home, "#settings-link[href='/alice/parametres']")
    {:ok, display, _} = live(conn, "/alice/parametres")
    assert has_element?(display, "#theme-settings")
    assert has_element?(display, "#settings-page.settings-page:not(.setup-section)")

    assert has_element?(
             display,
             "#settings-title-breadcrumb a[href='/alice']",
             "Retour à l’accueil"
           )

    refute has_element?(display, "#student-subjects-card")
    refute has_element?(display, "#question-types-card")
    {:ok, settings, _} = live(conn, "/alice/matieres/parametres")
    refute has_element?(settings, "#theme-settings")
    assert has_element?(settings, "#subjects-settings-page.settings-page:not(.setup-section)")

    assert has_element?(
             settings,
             "#subjects-settings-title-breadcrumb a[href='/alice']",
             "Retour à l’accueil"
           )

    assert has_element?(settings, "#manage-student-subjects[href='/alice/parametres/matieres']")
    assert has_element?(settings, "#manage-question-types[href='/alice/parametres/types']")
    {:ok, other, _} = live(conn, "/marius/matieres/parametres")
    assert has_element?(other, "#student-subjects-card h3", "Marius")
  end

  test "duplicate names show a flash error and preserve the form", %{conn: conn} do
    profile()
    {:ok, _} = QuestionDefinitions.seed!()
    [existing, edited | _] = QuestionDefinitions.list()
    {:ok, view, _} = live(conn, "/alice/parametres/types/#{edited.id}")
    view |> form("#type-editor", type: %{name: existing.name}) |> render_submit()
    assert has_element?(view, "#flash-error", "Ce nom existe déjà.")
    assert has_element?(view, "#type_name[aria-invalid=true][aria-describedby=flash-error]")
    refute has_element?(view, "#type-editor", "Ce nom existe déjà.")
    assert has_element?(view, "#type_name[value='#{existing.name}']")
    assert QuestionDefinitions.get!(edited.id).name == edited.name
    view |> form("#type-editor", type: %{name: "Nom disponible"}) |> render_change()
    refute has_element?(view, "#flash-error")
    refute has_element?(view, "#type_name[aria-invalid=true]")
    refute has_element?(view, "#type_name[aria-describedby]")
    view |> form("#type-editor", type: %{name: "Nom disponible"}) |> render_submit()
    assert_redirect(view, "/alice/parametres/types")
    assert QuestionDefinitions.get!(edited.id).name == "Nom disponible"
  end

  test "create edit filter and delete a common type from the UI", %{conn: conn} do
    profile()
    {:ok, view, _} = live(conn, "/alice/parametres/types/nouveau")
    refute has_element?(view, "#type-tab-correction")
    assert has_element?(view, "textarea#example_text")

    attrs = %{
      name: "Comparer",
      subjects: ["svt", "histoire-geo"],
      modes: ["classic", "flashcard"],
      response_kind: "long_text",
      instruction_kind: "dynamic",
      content_kind: "text",
      content_presence: "required",
      work_duration: "medium",
      help_classic: "Explique ta réponse.",
      help_flashcard: ""
    }

    view |> form("#type-editor", type: attrs) |> render_submit()
    assert_redirect(view, "/alice/parametres/types")
    [type] = QuestionDefinitions.list()
    {:ok, other, _} = live(conn, "/marius/parametres/types")
    assert has_element?(other, "#edit-type-#{type.id}")
    other |> form("#type-filters", filter: %{subject: "anglais"}) |> render_change()
    refute has_element?(other, "#edit-type-#{type.id}")
    {:ok, edit, _} = live(conn, "/marius/parametres/types/#{type.id}")
    edit |> form("#type-editor", type: %{name: "Comparer autrement"}) |> render_submit()
    assert QuestionDefinitions.get!(type.id).name == "Comparer autrement"
    {:ok, index, _} = live(conn, "/alice/parametres/types")
    index |> element("#delete-type-#{type.id}") |> render_click()
    assert has_element?(index, "#delete-type-modal")
    index |> element("#confirm-delete-type") |> render_click()
    refute Repo.get(Study.QuestionDefinition, type.id)
  end

  test "filters survive editing, saving, cancelling and breadcrumb navigation", %{conn: conn} do
    profile()
    {:ok, _} = QuestionDefinitions.seed!()
    type = Enum.find(QuestionDefinitions.list(), &(&1.name == "Dessin de géométrie"))
    filters = %{"search" => "Dessin", "subject" => "mathematiques", "mode" => "classic"}
    list_path = "/alice/parametres/types?" <> URI.encode_query(filters)
    edit_path = "/alice/parametres/types/#{type.id}?" <> URI.encode_query(filters)
    {:ok, view, _} = live(conn, "/alice/parametres/types")
    view |> form("#type-filters", filter: filters) |> render_change()
    assert_patch(view, list_path)
    assert has_element?(view, "#edit-type-#{type.id}[href='#{edit_path}']")
    {:ok, editor, _} = live(conn, edit_path)
    assert has_element?(editor, "#cancel-type[href='#{list_path}']")
    assert has_element?(editor, "#type-editor-breadcrumb[href='#{list_path}']")
    editor |> form("#type-editor", type: %{name: type.name}) |> render_submit()
    assert_redirect(editor, list_path)
    {:ok, restored, _} = live(conn, list_path)
    assert has_element?(restored, "#filter_search[value='Dessin']")
    assert has_element?(restored, "#filter_subject option[value='mathematiques'][selected]")
    assert has_element?(restored, "#filter_mode option[value='classic'][selected]")
    assert has_element?(restored, "#edit-type-#{type.id}")
  end

  test "each media preview uses the configured response and work mode", %{conn: conn} do
    profile()
    {:ok, _} = QuestionDefinitions.seed!()

    for {name, selector} <- [
          {"Analyse de document", "#preview-document"},
          {"Carte à compléter", "#preview-image img"},
          {"Compréhension orale",
           "#preview-audio audio[src='/audio/question-examples/english.mp3']"},
          {"Prononciation", "#preview-voice[phx-hook='QuestionPreviewRecorder']"},
          {"Dessin de géométrie", "#preview-photo-input[type=file]"}
        ] do
      type = Enum.find(QuestionDefinitions.list(), &(&1.name == name))
      {:ok, view, _} = live(conn, "/alice/parametres/types/#{type.id}")
      assert has_element?(view, selector)

      if name == "Dessin de géométrie" do
        assert has_element?(view, "#preview-webcam[phx-hook=WebcamCapture] [data-camera-open]")

        refute has_element?(view, "#preview-support")
        view |> form("#type-preview-mode", %{mode: "flashcard"}) |> render_change()
        assert has_element?(view, "#preview-unavailable")
      end
    end
  end

  test "definition previews and controls share the same question presentation", %{conn: conn} do
    profile()
    {:ok, _} = QuestionDefinitions.seed!()
    type = Enum.find(QuestionDefinitions.list(), &(&1.name == "Définition"))
    {:ok, preview, _} = live(conn, "/alice/parametres/types/#{type.id}")
    preview |> form("#type-preview-mode", %{mode: "classic"}) |> render_change()
    preview |> form("#type-example", example: %{text: "La Préhistoire"}) |> render_change()

    q = question() |> Map.merge(%{"prompt" => type.instruction, "text" => "La Préhistoire"})
    exam = exam(lesson(profile()), [q])
    {:ok, control, _} = live(conn, "/alice/controles/#{exam.id}")

    for {view, root} <- [{preview, "#question-type-preview"}, {control, "#question-q1"}] do
      assert has_element?(view, "#{root}.question .question-meta .question-number", "1")
      assert has_element?(view, "#{root}.question h2", type.instruction)
      assert has_element?(view, "#{root}.question .reading-text", "La Préhistoire")
      assert has_element?(view, "#{root}.question label.sr-only")
    end

    preview |> form("#type-preview-mode", %{mode: "flashcard"}) |> render_change()
    assert has_element?(preview, "#question-type-preview.flashcard-front .flashcard-eyebrow")
    assert has_element?(preview, "#question-type-preview .flashcard-prompt", type.instruction)
    assert has_element?(preview, "#question-type-preview .reading-text", "La Préhistoire")
  end

  test "validation and preview changes preserve entered data", %{conn: conn} do
    profile()
    {:ok, view, _} = live(conn, "/alice/parametres/types/nouveau")

    view
    |> form("#type-editor", type: %{name: "", subjects: [""], modes: [""]})
    |> render_submit()

    assert has_element?(view, "#type-editor [role=alert]")

    view
    |> form("#type-editor",
      type: %{content_kind: "document", modes: ["classic", "flashcard"], subjects: ["svt"]}
    )
    |> render_change()

    view
    |> form("#type-example", example: %{document: "Première ligne\nDeuxième ligne"})
    |> render_change()

    assert has_element?(view, "#preview-document .document-body", "Première ligne")
  end
end

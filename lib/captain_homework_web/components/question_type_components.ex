defmodule CaptainHomeworkWeb.QuestionTypeComponents do
  @moduledoc "Question previews; form controls are shared through CoreComponents."
  use CaptainHomeworkWeb, :html
  alias CaptainHomework.{Study, QuestionTemplates}

  attr :type, :map, required: true
  attr :mode, :string, required: true
  attr :example, :map, required: true
  attr :subject, :string, default: nil
  attr :corrected, :boolean, default: false
  attr :ordering_answer, :string, default: ""

  def question_preview(assigns) do
    subject =
      assigns.subject ||
        Enum.find_value(Study.subjects(), fn s -> if s.id in assigns.type.subjects, do: s.id end)

    assigns = assign(assigns, example: QuestionTemplates.question(assigns.example, subject))

    assigns =
      assign(assigns,
        prompt:
          if(assigns.type.instruction_kind == "fixed",
            do: QuestionTemplates.render(assigns.type.instruction, subject),
            else: assigns.example["prompt"]
          ),
        help:
          if(assigns.mode == "classic",
            do: QuestionTemplates.render(assigns.type.help_classic, subject),
            else: QuestionTemplates.render(assigns.type.help_flashcard, subject)
          ),
        subject_name:
          Enum.find_value(Study.subjects(), "Matière", fn s ->
            if s.id == subject, do: s.name
          end)
      )

    ~H"""
    <div
      id="question-type-preview"
      class={[
        "admin-preview-card",
        @mode == "flashcard" && "flash flashcard-front",
        @mode == "classic" && "classic question"
      ]}
    >
      <%= if @corrected do %>
        <h3>Aperçu de la correction</h3>
        <p class="muted">La correction dépendra de la question et de sa réponse attendue.</p>
        <button id="preview-back" type="button" class="button primary" phx-click="preview_back">
          Revenir à la question
        </button>
      <% else %>
        <.flashcard_heading :if={@mode == "flashcard"} subject={@subject_name} prompt={@prompt} />
        <.question_heading :if={@mode == "classic"} prompt={@prompt} type_label={@type.name} />
        <div
          :if={@type.content_presence != "none" and @type.response_kind != "ordering"}
          id="preview-support"
        >
          <.question_text
            :if={@type.content_kind == "text" and String.trim(@example["text"] || "") != ""}
            text={@example["text"]}
          />
          <article
            :if={@type.content_kind == "document"}
            class="sample-document"
            id="preview-document"
          >
            <small>DOCUMENT · 1 PAGE</small>
            <h4>Une journée au village</h4>
            <div class="document-body">{@example["document"]}</div>
            <p class="sample-source">Texte fictif créé pour cet aperçu.</p>
          </article>
          <figure :if={@type.content_kind == "image"} class="sample-image" id="preview-image">
            <img
              src={~p"/images/question-examples/stratigraphy.svg"}
              alt="Coupe archéologique schématique avec trois couches numérotées"
            />
            <figcaption class="sample-source">Coupe archéologique · Schéma d’exemple</figcaption>
          </figure>
          <figure :if={@type.content_kind == "audio"} class="sample-audio" id="preview-audio">
            <audio
              controls
              preload="metadata"
              src={
                if @type.example["audio"] == "english",
                  do: ~p"/audio/question-examples/english.mp3",
                  else: ~p"/audio/question-examples/village.mp3"
              }
            />
          </figure>
        </div>
        <p :if={@help && @help != ""} class="preview-help">{@help}</p>
        <.form
          for={to_form(%{}, as: :answer)}
          id="preview-response-form"
          phx-change="preview_answer"
          phx-submit="preview_validate"
        >
          <%= case @type.response_kind do %>
            <% "ordering" -> %>
              <.ordering_input
                id="preview-ordering"
                question_id="preview"
                name="answer[order]"
                options={CaptainHomework.Exams.Ordering.example_options(@example["text"] || "")}
                value={@ordering_answer}
              />
            <% "single_choice" -> %>
              <div class="options">
                <label
                  :for={
                    {text, i} <-
                      Enum.with_index([
                        "Lascaux et Chauvet",
                        "Versailles et Chambord",
                        "Athènes et Rome"
                      ])
                  }
                  class="option"
                >
                  <input type="radio" name="answer[choice]" value={i} />{text}
                </label>
              </div>
            <% kind when kind in ["legends", "cloze"] -> %>
              <.symbol_answer
                id="preview-slot-symbols"
                context={
                  Enum.join([@prompt || "", @example["text"] || "", @example["document"] || ""], "\n")
                }
              >
                <div class={if @mode == "classic", do: "slot-inputs", else: "preview-slots"}>
                  <div :for={i <- 1..3}>
                    <label for={"preview-slot-#{i}"}>
                      {if kind == "legends", do: "Repère", else: "Mot manquant"} {i}
                    </label>
                    <.input
                      wrapper={false}
                      id={"preview-slot-#{i}"}
                      name={"answer[slot_#{i}]"}
                      autocomplete="off"
                      autocorrect="off"
                      spellcheck="false"
                    />
                  </div>
                </div>
              </.symbol_answer>
            <% "recording" -> %>
              <div
                id="preview-voice"
                phx-hook="QuestionPreviewRecorder"
                phx-update="ignore"
                class="preview-voice"
              >
                <p data-status role="status">Prêt à enregistrer</p>
                <button type="button" class="button secondary" data-record>
                  <.icon name="microphone" /> Enregistrer ma voix
                </button>
                <audio data-playback controls hidden />
                <p class="sample-source">Enregistrement local pour l’aperçu, non envoyé.</p>
              </div>
            <% kind when kind in ["photo", "photo_justification"] -> %>
              <div id="preview-photo" phx-hook="QuestionPreviewPhoto" phx-update="ignore">
                <.photo_answer id="preview-photo-widget" local_preview>
                  <:picker>
                    <.webcam_capture id="preview-webcam" />
                    <label class="button primary photo-picker" for="preview-photo-input">
                      <.icon name="camera" />
                      <span data-photo-label class="photo-picker-mobile-label">
                        Prendre ou choisir une photo
                      </span>
                      <span class="photo-picker-desktop-label">Choisir une photo</span>
                      <input
                        id="preview-photo-input"
                        class="photo-file-input"
                        type="file"
                        accept="image/jpeg,image/png,image/webp"
                        capture="environment"
                      />
                    </label>
                  </:picker>
                  <:remove>
                    <button type="button" class="button secondary" data-photo-remove hidden>
                      Supprimer
                    </button>
                  </:remove>
                </.photo_answer>
              </div>
              <.symbol_answer
                :if={kind == "photo_justification"}
                id="preview-justification-symbols"
                label="Ta justification"
                context={
                  Enum.join([@prompt || "", @example["text"] || "", @example["document"] || ""], "\n")
                }
              >
                <label class="sr-only" for="preview-justification">Ta justification</label>
                <.input
                  wrapper={false}
                  type="textarea"
                  id="preview-justification"
                  name="answer[justification]"
                  rows="3"
                />
              </.symbol_answer>
            <% "long_text" -> %>
              <.symbol_answer
                id="preview-text-symbols"
                context={
                  Enum.join([@prompt || "", @example["text"] || "", @example["document"] || ""], "\n")
                }
              >
                <label for="preview-answer" class="sr-only">Ta réponse</label>
                <.input
                  wrapper={false}
                  type="textarea"
                  id="preview-answer"
                  name="answer[text]"
                  rows={if @mode == "classic", do: 5, else: 3}
                  autocomplete="off"
                  autocorrect="off"
                  autocapitalize="off"
                  spellcheck="false"
                />
              </.symbol_answer>
            <% _ -> %>
              <.symbol_answer
                id="preview-text-symbols"
                context={
                  Enum.join([@prompt || "", @example["text"] || "", @example["document"] || ""], "\n")
                }
              >
                <label for="preview-answer" class="sr-only">Ta réponse</label>
                <.input
                  wrapper={false}
                  id="preview-answer"
                  name="answer[text]"
                  autocomplete="off"
                  autocorrect="off"
                  autocapitalize="off"
                  spellcheck="false"
                />
              </.symbol_answer>
          <% end %>
          <button
            :if={@mode == "flashcard"}
            id="preview-validate"
            class="button primary"
            type="submit"
          >
            Valider
          </button>
        </.form>
      <% end %>
    </div>
    """
  end
end

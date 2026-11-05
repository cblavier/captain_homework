defmodule CaptainHomeworkWeb.QuestionComponents do
  @moduledoc "Shared question presentation and answer controls for previews and exams."
  use Phoenix.Component
  import CaptainHomeworkWeb.CoreComponents
  import CaptainHomeworkWeb.SymbolComponents
  import CaptainHomeworkWeb.PhotoAnswerComponents

  attr :question, :map, required: true
  attr :mode, :string, required: true
  attr :subject, :string, default: ""
  attr :type_label, :string, default: ""
  attr :index, :integer, default: 1
  attr :exam, :map, default: nil
  attr :profile, :map, default: nil
  attr :shared_support, :boolean, default: false
  attr :show_help, :boolean, default: true
  attr :audio_src, :string, default: nil
  attr :images, :list, default: nil

  def question_content(assigns) do
    {prompt, text} = content(assigns.question, assigns.mode)
    support_text = readable_text(assigns.question["support_text"] || "")
    assigns = assign(assigns, prompt: prompt, text: text, support_text: support_text)

    ~H"""
    <div class={["question-content", "question-content-#{@mode}"]}>
      <.flashcard_heading
        :if={@mode == "flashcard"}
        id={if @question["id"] != "preview", do: "flashcard-question"}
        subject={@subject}
        prompt={@prompt}
      />
      <.question_heading
        :if={@mode == "classic"}
        prompt={@prompt}
        type_label={@type_label}
        index={@index}
        points={@question["points"] || 1}
      />
      <.question_images
        :if={!@shared_support}
        question={@question}
        exam={@exam}
        profile={@profile}
        sources={@images}
      />
      <.question_audio question={@question} exam={@exam} profile={@profile} src={@audio_src} />
      <.question_text
        :if={!@shared_support and String.trim(@support_text) != ""}
        text={@support_text}
      />
      <.question_text
        :if={
          @text != "" and (@shared_support or @text != @support_text) and
            CaptainHomework.Exams.SupportGroups.question_text_visible?(
              Map.put(@question, "text", @text),
              @shared_support
            )
        }
        text={@text}
      />
      <.diagram
        :if={@question["type"] == "diagram" and is_map(@question["diagram"])}
        question={@question}
      />
      <p
        :if={@show_help and @question["help"] not in [nil, ""]}
        id={"question-help-#{@question["id"]}"}
        class="preview-help"
      >
        {@question["help"]}
      </p>
    </div>
    """
  end

  attr :question, :map, required: true
  attr :mode, :string, required: true
  attr :kind, :string, default: nil
  attr :preview, :boolean, default: false
  attr :value, :any, default: nil
  attr :disabled, :boolean, default: false
  attr :context, :string, default: nil
  attr :upload, :any, default: nil
  attr :photo_src, :string, default: nil
  attr :completed, :boolean, default: false
  slot :text_actions

  def question_response(assigns) do
    kind = assigns.kind || response_kind(assigns.question["type"])
    namespace = if assigns.preview, do: "preview", else: assigns.mode
    id = assigns.question["id"]
    name = if assigns.preview, do: "answer", else: "answers[#{id}]"
    field_name = if assigns.preview, do: "answer[text]", else: name

    response_id =
      case namespace do
        "preview" -> "preview-answer"
        "flashcard" -> "flashcard-response"
        _ -> "answer-#{id}"
      end

    symbols_id =
      case namespace do
        "preview" ->
          if(kind in ["cloze", "legends"],
            do: "preview-slot-symbols",
            else: "preview-text-symbols"
          )

        "flashcard" ->
          "flashcard-symbols-#{id}"

        _ ->
          "symbols-#{id}"
      end

    assigns =
      assign(assigns,
        kind: kind,
        namespace: namespace,
        name: name,
        field_name: field_name,
        response_id: response_id,
        symbols_id: symbols_id,
        context: assigns.context || CaptainHomework.Symbols.context(assigns.question, [])
      )

    ~H"""
    <div class={["question-response", "question-response-#{@mode}"]} data-response-kind={@kind}>
      <.ordering_input
        :if={@kind == "ordering"}
        id={if @preview, do: "preview-ordering", else: "ordering-#{@question["id"]}"}
        question_id={@question["id"]}
        name={if @preview, do: "answer[order]", else: @name}
        options={@question["options"] || []}
        value={@value}
        disabled={@disabled}
      />
      <div :if={@kind == "single_choice"} class="options">
        <label
          :for={{option, index} <- Enum.with_index(@question["options"] || [])}
          class={["option", @value == option && "selected"]}
        >
          <input
            type="radio"
            id={
              if @namespace == "flashcard",
                do: "flashcard-option-#{index}",
                else: "#{@response_id}-option-#{index}"
            }
            name={if @preview, do: "answer[choice]", else: @name}
            value={option}
            checked={@value == option}
            disabled={@disabled}
          />
          <span :if={@mode == "classic"} class="option-letter">{<<65 + index>>}</span><span>{option}</span>
        </label>
      </div>
      <.question_photo
        :if={@kind in ["photo", "photo_justification"]}
        question={@question}
        preview={@preview}
        src={@photo_src}
        upload={@upload}
        disabled={@disabled}
        completed={@completed}
      />
      <.question_recording
        :if={@kind == "recording"}
        id={if @preview, do: "preview-voice", else: "voice-#{@question["id"]}"}
      />
      <.symbol_answer
        :if={@kind in ["short_text", "long_text", "cloze", "legends", "photo_justification"]}
        id={@symbols_id}
        context={@context}
        disabled={@disabled}
        label={if @kind == "photo_justification", do: "Ta justification", else: "Ta réponse"}
      >
        <%= if @kind in ["cloze", "legends"] do %>
          <div class="slot-inputs">
            <div :for={{slot, index} <- Enum.with_index(@question["slots"] || [])}>
              <label
                for={slot_id(@namespace, @question["id"], slot, index)}
                class={@kind == "legends" && "slot-marker"}
              >
                {if @kind == "legends",
                  do: String.replace(slot, ~r/^Repère\s+(\d+)$/iu, "\\1"),
                  else: slot}
              </label>
              <.input
                wrapper={false}
                id={slot_id(@namespace, @question["id"], slot, index)}
                name={if @preview, do: "answer[slot_#{index + 1}]", else: "#{@name}[#{slot}]"}
                value={slot_value(@value, slot)}
                disabled={@disabled}
                maxlength="2000"
                phx-debounce="300"
                autocomplete={if @preview, do: "on", else: "off"}
                autocorrect={if @preview, do: "on", else: "off"}
                autocapitalize={if @preview, do: "sentences", else: "off"}
                spellcheck={if @preview, do: "true", else: "false"}
                writingsuggestions={if @preview, do: "true", else: "false"}
              />
            </div>
          </div>
        <% else %>
          <label class="sr-only" for={@response_id}>
            {if @kind == "photo_justification", do: "Ta justification", else: "Ta réponse"}
          </label>
          <.input
            wrapper={false}
            id={@response_id}
            name={@field_name}
            type={if @kind in ["long_text", "photo_justification"], do: "textarea", else: "text"}
            rows={
              if @kind in ["long_text", "photo_justification"],
                do: if(@mode == "classic", do: 5, else: 3)
            }
            value={@value || ""}
            disabled={@disabled}
            maxlength="12000"
            phx-debounce="300"
            autocomplete={if @preview, do: "on", else: "off"}
            autocorrect={if @preview, do: "on", else: "off"}
            autocapitalize={if @preview, do: "sentences", else: "off"}
            spellcheck={if @preview, do: "true", else: "false"}
            writingsuggestions={if @preview, do: "true", else: "false"}
          />
          {render_slot(@text_actions)}
        <% end %>
      </.symbol_answer>
    </div>
    """
  end

  def response_kind(type) do
    case type do
      "ordering" -> "ordering"
      "mcq" -> "single_choice"
      "cloze" -> "cloze"
      "diagram" -> "legends"
      "photo" -> "photo"
      type when type in ["long", "reading"] -> "long_text"
      _ -> "short_text"
    end
  end

  defp slot_id("preview", _, _, index), do: "preview-slot-#{index + 1}"
  defp slot_id("flashcard", _, _, index), do: "flashcard-slot-#{index}"
  defp slot_id(_, id, slot, _), do: "answer-#{id}-#{slot}"
  defp slot_value(value, slot) when is_map(value), do: value[slot] || ""
  defp slot_value(_, _), do: ""

  defp content(question, "flashcard") do
    prompt = question["prompt"] || ""
    text = question["text"] || ""

    heading =
      prompt |> String.trim() |> String.downcase() |> String.trim_trailing(":") |> String.trim()

    {prompt, text} =
      cond do
        CaptainHomework.Exams.Flashcards.answer_repeated_in_text?(question) ->
          {prompt, ""}

        question["type"] == "definition" and heading in ["definition", "définition"] and
            String.trim(text) != "" ->
          {text, ""}

        true ->
          {prompt, text}
      end

    {keep_punctuation_with_word(prompt), readable_text(text)}
  end

  defp content(question, _), do: {question["prompt"] || "", readable_text(question["text"] || "")}
  defp readable_text(text), do: Regex.replace(~r/\{\{([^}]+)\}\}/, text, "_____ (\\1) _____")

  defp keep_punctuation_with_word(text) do
    text = Regex.replace(~r/\s+([?!;:»])/u, text, "\u00A0\\1")
    Regex.replace(~r/«\s+/u, text, "«\u00A0")
  end

  attr :id, :string, required: true

  def question_recording(assigns) do
    ~H"""
    <div
      id={@id}
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
    """
  end

  attr :question, :map, required: true
  attr :preview, :boolean, default: false
  attr :src, :string, default: nil
  attr :upload, :any, default: nil
  attr :disabled, :boolean, default: false
  attr :completed, :boolean, default: false

  def question_photo(assigns) do
    assigns =
      assign(assigns,
        photo_id:
          if(assigns.preview, do: "preview-photo", else: "photo-#{assigns.question["id"]}")
      )

    ~H"""
    <div
      id={@photo_id}
      phx-hook={if @preview, do: "QuestionPreviewPhoto"}
      phx-update={if @preview, do: "ignore"}
    >
      <.photo_answer
        id={if @preview, do: "preview-photo-widget", else: "photo-response-#{@question["id"]}"}
        src={@src}
        local_preview={@preview}
      >
        <:picker :if={!@disabled and !@completed}>
          <.webcam_capture
            id={if @preview, do: "preview-webcam", else: "webcam-#{@question["id"]}"}
            upload_name={if @upload, do: @upload.name}
          />
          <label
            id={if !@preview, do: "choose-photo-#{@question["id"]}"}
            class="button primary photo-picker"
            for={if @preview, do: "preview-photo-input"}
            hidden={@upload && @upload.entries != []}
          >
            <.icon name="camera" />
            <span data-photo-label class="photo-picker-mobile-label">
              {if @src, do: "Remplacer la photo", else: "Prendre ou choisir une photo"}
            </span>
            <span class="photo-picker-desktop-label">Choisir une photo</span>
            <%= if @preview do %>
              <input
                id="preview-photo-input"
                class="photo-file-input"
                type="file"
                accept="image/jpeg,image/png,image/webp"
                capture="environment"
              />
            <% else %>
              <.live_file_input
                upload={@upload}
                class="photo-file-input"
                aria-label="Photo de ton dessin"
              />
            <% end %>
          </label>
          <div :for={entry <- if(@upload, do: @upload.entries, else: [])}>
            <p :if={entry.valid?} role="status">Envoi : {entry.progress} %</p>
            <p :for={error <- upload_errors(@upload, entry)} class="error" role="alert">
              {if error == :too_large,
                do: "La photo dépasse 12 Mo.",
                else: "Choisis une photo JPEG, PNG ou WebP valide."}
            </p>
            <button
              type="button"
              class="button secondary"
              phx-click="cancel_upload"
              phx-value-name={@upload.name}
              phx-value-ref={entry.ref}
            >
              Annuler
            </button>
          </div>
        </:picker>
        <:remove :if={!@disabled and !@completed and (@preview or @src != nil)}>
          <button
            id={if !@preview, do: "remove-photo-#{@question["id"]}"}
            type="button"
            class="button secondary"
            data-photo-remove
            hidden={@preview}
            phx-click={if !@preview, do: "remove_drawing_photo"}
            phx-value-id={@question["id"]}
          >
            Supprimer
          </button>
        </:remove>
      </.photo_answer>
    </div>
    """
  end
end

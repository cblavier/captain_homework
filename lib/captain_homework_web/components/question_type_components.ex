defmodule CaptainHomeworkWeb.QuestionTypeComponents do
  @moduledoc "Adapts catalogue examples to the shared question renderers."
  use CaptainHomeworkWeb, :html
  alias CaptainHomework.{Study, QuestionTemplates, QuestionDefinitions}
  import CaptainHomeworkWeb.QuestionComponents

  attr :type, :map, required: true
  attr :mode, :string, required: true
  attr :example, :map, required: true
  attr :subject, :string, default: nil
  attr :corrected, :boolean, default: false
  attr :ordering_answer, :string, default: ""
  attr :answer, :map, default: %{}

  def question_preview(assigns) do
    subject =
      assigns.subject ||
        Enum.find_value(Study.subjects(), fn s -> if s.id in assigns.type.subjects, do: s.id end)

    assigns =
      assign(assigns,
        example:
          QuestionTemplates.question(Map.merge(assigns.type.example, assigns.example), subject)
      )

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

    assigns =
      assign(assigns, question: preview_question(assigns), form: to_form(%{}, as: :answer))

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
        <.question_content
          question={@question}
          mode={@mode}
          subject={@subject_name}
          type_label={@type.name}
          audio_src={preview_audio(@type)}
          images={preview_images(@type)}
        />
        <.form
          for={@form}
          id="preview-response-form"
          phx-change="preview_answer"
          phx-submit="preview_validate"
        >
          <.question_response
            question={@question}
            mode={@mode}
            kind={@type.response_kind}
            preview
            value={preview_value(@type.response_kind, @question, @answer, @ordering_answer)}
          />
          <button
            :if={@mode == "flashcard"}
            id="preview-validate"
            class="button primary question-submit"
            type="submit"
          >
            Valider
          </button>
        </.form>
      <% end %>
    </div>
    """
  end

  defp preview_value("ordering", _, _, ordering), do: ordering
  defp preview_value("single_choice", _, answer, _), do: answer["choice"]

  defp preview_value(kind, question, answer, _) when kind in ["cloze", "legends"] do
    question["slots"]
    |> Enum.with_index(1)
    |> Map.new(fn {slot, index} -> {slot, answer["slot_#{index}"] || ""} end)
  end

  defp preview_value(_, _, answer, _), do: answer["text"]

  defp preview_question(assigns) do
    type = assigns.type
    example = assigns.example

    text =
      if type.content_presence == "none" or type.response_kind == "ordering" do
        ""
      else
        case type.content_kind do
          "text" -> example["text"] || ""
          "document" -> example["document"] || ""
          _ -> ""
        end
      end

    %{
      "id" => "preview",
      "type" => QuestionDefinitions.engine_format(type),
      "prompt" => assigns.prompt,
      "help" => assigns.help,
      "text" => text,
      "options" =>
        if(type.response_kind == "ordering",
          do: CaptainHomework.Exams.Ordering.example_options(example["text"] || ""),
          else:
            example["options"] ||
              ["Lascaux et Chauvet", "Versailles et Chambord", "Athènes et Rome"]
        ),
      "slots" =>
        example["slots"] ||
          Enum.map(1..3, fn i ->
            "#{if type.response_kind == "legends", do: "Repère", else: "Mot manquant"} #{i}"
          end)
    }
  end

  defp preview_audio(%{content_kind: "audio", content_presence: presence} = type)
       when presence != "none",
       do:
         if(type.example["audio"] == "english",
           do: "/audio/question-examples/english.mp3",
           else: "/audio/question-examples/village.mp3"
         )

  defp preview_audio(_), do: nil

  defp preview_images(%{content_kind: "image", content_presence: presence})
       when presence != "none",
       do: [
         %{
           id: "sample",
           src: "/images/question-examples/stratigraphy.svg",
           alt: "Coupe archéologique schématique avec trois couches numérotées"
         }
       ]

  defp preview_images(_), do: []
end

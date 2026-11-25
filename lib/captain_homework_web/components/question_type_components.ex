defmodule CaptainHomeworkWeb.QuestionTypeComponents do
  @moduledoc "Adapts catalogue examples to the shared question renderers."
  use CaptainHomeworkWeb, :html
  alias CaptainHomework.{Study, QuestionTemplates, QuestionDefinitions}
  alias CaptainHomework.Study.QuestionDefinition
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
        type_label: QuestionTemplates.render(assigns.type.name, subject),
        content_kinds:
          if(assigns.type.content_presence == "none",
            do: [],
            else: QuestionDefinition.content_kinds(assigns.type)
          ),
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
          type_label={@type_label}
          audio_src={preview_audio(@type, @content_kinds)}
          images={preview_images(@type, @content_kinds)}
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
    kinds = assigns.content_kinds

    text =
      cond do
        type.response_kind == "ordering" -> ""
        "text" in kinds -> example["text"] || ""
        kinds == ["document"] -> example["document"] || ""
        true -> ""
      end

    document =
      if "document" in kinds do
        if kinds == ["document"] and type.response_kind != "ordering",
          do: example["support_text"],
          else: example["support_text"] || example["document"]
      end

    %{
      "id" => "preview",
      "type" => QuestionDefinitions.engine_format(type),
      "prompt" => assigns.prompt,
      "text" => text,
      "support_text" => document || "",
      "diagram" => if("image" in kinds or "document" in kinds, do: example["diagram"]),
      "options" =>
        if(type.response_kind == "ordering",
          do: CaptainHomework.Exams.Ordering.example_options(example["text"] || ""),
          else:
            example["options"] ||
              ["Lascaux et Chauvet", "Versailles et Chambord", "Athènes et Rome"]
        ),
      "slots" =>
        example["slots"] ||
          if(type.response_kind == "cloze" and String.contains?(text, "{{"),
            do: Regex.scan(~r/\{\{([^}]+)\}\}/, text, capture: :all_but_first) |> List.flatten(),
            else:
              Enum.map(1..3, fn i ->
                "#{if type.response_kind == "legends", do: "Repère", else: "Mot manquant"} #{i}"
              end)
          )
    }
  end

  defp preview_audio(%{id: id, example: %{"audio" => %{"id" => asset_id}}}, ["audio"]),
    do: "/parametres/types/#{id}/exemples/#{asset_id}"

  defp preview_audio(type, ["audio"]),
    do:
      if(type.example["audio"] == "english",
        do: "/audio/question-examples/english.mp3",
        else: "/audio/question-examples/village.mp3"
      )

  defp preview_audio(_, _), do: nil

  defp preview_images(type, kinds) do
    cond do
      ("image" in kinds or "document" in kinds) and is_list(type.example["images"]) and
          type.example["images"] != [] ->
        Enum.map(type.example["images"], fn asset ->
          %{
            id: asset["id"],
            src: "/parametres/types/#{type.id}/exemples/#{asset["id"]}",
            alt: asset["alt"] || "Illustration de l’exemple"
          }
        end)

      "image" in kinds ->
        [
          %{
            id: "sample",
            src: "/images/question-examples/stratigraphy.svg",
            alt: "Coupe archéologique schématique avec trois couches numérotées"
          }
        ]

      true ->
        []
    end
  end
end

defmodule CaptainHomeworkWeb.QuestionTypePicker do
  use Phoenix.Component
  attr :id, :string, default: "question-types"
  attr :input_prefix, :string, default: "question-type"
  attr :types, :list, required: true
  attr :groups, :list, required: true
  attr :selected, :list, required: true
  attr :mode, :string, required: true
  attr :subject, :string, default: nil

  def question_type_picker(assigns) do
    ~H"""
    <fieldset
      id={@id}
      class="question-types"
    >
      <legend class="form-field-label">Types de questions</legend>
      <p :if={@types == []} class="notice">
        Aucun type disponible. Ajoute un type dans le catalogue commun.
      </p>
      <input type="hidden" name="question_types[]" value="" />
      <section
        :for={{duration, label, types} <- @groups}
        id={"#{@id}-#{duration}"}
        class="question-type-group"
        aria-labelledby={"#{@id}-#{duration}-title"}
      >
        <h3 id={"#{@id}-#{duration}-title"}>{label}</h3>
        <div class="subject-checkbox-grid">
          <label
            :for={type <- types}
            class="subject-checkbox"
            for={"#{@input_prefix}-#{type.id}"}
            title={if type.instruction_kind == "fixed", do: type.instruction}
          >
            <input
              type="checkbox"
              id={"#{@input_prefix}-#{type.id}"}
              name="question_types[]"
              value={type.id}
              checked={type.id in @selected}
              disabled={
                not CaptainHomework.QuestionDefinitions.mode_allowed?(type, @mode) or
                  not CaptainHomework.QuestionDefinitions.generation_supported?(type)
              }
            />
            <span>
              {CaptainHomework.QuestionTemplates.render(type.name, @subject)}<small
                :if={not CaptainHomework.QuestionDefinitions.generation_supported?(type)}
                class="muted"
              > · Bientôt disponible</small>
            </span>
          </label>
        </div>
      </section>
      <p :if={@selected == []} id={@id <> "-error"} class="error">
        Choisis au moins un type de question.
      </p>
    </fieldset>
    """
  end
end

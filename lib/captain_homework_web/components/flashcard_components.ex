defmodule CaptainHomeworkWeb.FlashcardComponents do
  use Phoenix.Component
  import CaptainHomeworkWeb.CoreComponents
  import CaptainHomeworkWeb.QuestionComponents
  alias CaptainHomework.Exams.Flashcards

  def flashcard_active?(%{format: "flashcard", status: status}),
    do: status in ["in_progress", "grading"]

  def flashcard_active?(_), do: false

  attr :profile, :map, default: nil
  attr :exam, :map, required: true
  attr :answers, :map, required: true
  attr :subject, :string, required: true
  attr :close_path, :string, default: nil
  attr :error, :string, default: nil
  slot :footer

  def flashcard(assigns) do
    question = Flashcards.current(assigns.exam)
    correction = assigns.exam.corrections[question["id"]]

    remaining = length(assigns.exam.questions) - assigns.exam.card_index - 1

    assigns =
      assign(assigns,
        question: question,
        correction: correction,
        remaining: remaining,
        flipped: not is_nil(correction),
        grading: assigns.exam.status == "grading",
        form: to_form(%{"answers" => assigns.answers})
      )

    ~H"""
    <section id="flashcard-session" aria-label="Révision par flashcards">
      <div id="flashcard-viewport" phx-hook="FlashcardViewport" phx-update="ignore" hidden />
      <header class={["flashcard-header", !@close_path && "flashcard-header-shared"]}>
        <.link
          :if={@close_path}
          navigate={@close_path}
          id="close-flashcards"
          class="icon-button"
          aria-label="Fermer les flashcards"
        >
          <.icon name="close" />
        </.link>
        <div class="flashcard-progress" id="flashcard-progress">
          <progress
            id="flashcard-progress-bar"
            value={map_size(@exam.corrections)}
            max={length(@exam.questions)}
            aria-label="Cartes corrigées"
            aria-valuetext={"#{map_size(@exam.corrections)} cartes corrigées sur #{length(@exam.questions)}"}
          />
          <span aria-label="Carte actuelle">{@exam.card_index + 1} / {length(@exam.questions)}</span>
        </div>
      </header>
      <div class="flashcard-scene" id="flashcard-scene">
        <div
          :if={@remaining >= 2}
          id="flashcard-underlay-2"
          class="flashcard-stack-card flashcard-stack-far"
          aria-hidden="true"
        />
        <div
          :if={@remaining >= 1}
          id="flashcard-underlay-1"
          class="flashcard-stack-card flashcard-stack-near"
          aria-hidden="true"
        />
        <div
          id="flashcard-inner"
          class={["flashcard-inner", @flipped && "is-flipped", @grading && "is-grading"]}
        >
          <div
            id={"flashcard-#{@question["id"]}"}
            class="flashcard-face flashcard-front"
            aria-hidden={to_string(@flipped)}
            inert={@flipped}
          >
            <div class="flashcard-content">
              <.question_content
                question={@question}
                mode="flashcard"
                subject={@subject}
                exam={@exam}
                profile={@profile}
              />
              <.form
                for={@form}
                id="flashcard-answer"
                autocomplete="off"
                autocapitalize="off"
                spellcheck="false"
                phx-change="save_answers"
                phx-submit="validate_card"
              >
                <input type="hidden" name="question_id" value={@question["id"]} />
                <fieldset disabled={@grading or @flipped}>
                  <.question_response
                    question={@question}
                    mode="flashcard"
                    value={@answers[@question["id"]]}
                    disabled={@grading or @flipped}
                  />
                </fieldset>
              </.form>
            </div>
            <footer class="flashcard-actions" id="flashcard-actions">
              <p :if={@error} id="flashcard-error" class="notice error" role="alert">{@error}</p>
              <button
                :if={!@flipped}
                id="validate-card"
                class="button primary question-submit"
                type="submit"
                form="flashcard-answer"
                disabled={@grading}
                aria-busy={to_string(@grading)}
                aria-label={if @grading, do: "Correction en cours", else: "Valider ma réponse"}
              >
                <span class="spinner" aria-hidden="true" />
                <span class="validate-card-label">Valider</span>
                <span class="validate-card-loading" aria-hidden="true">Correction en cours…</span>
              </button>
            </footer>
          </div>
          <div
            class="flashcard-face flashcard-back"
            aria-hidden={to_string(not @flipped)}
            inert={not @flipped}
          >
            <div
              :if={@correction}
              id="flashcard-correction"
              class="flashcard-content"
              role="status"
            >
              <h2
                id="flashcard-verdict"
                class={[
                  "flashcard-verdict",
                  if(@correction["fraction"] == 1,
                    do: "flashcard-correct",
                    else: "flashcard-incorrect"
                  )
                ]}
              >
                <span class="flashcard-verdict-icon" aria-hidden="true">
                  <.icon name={if @correction["fraction"] == 1, do: "check", else: "close"} />
                </span>
                {if @correction["fraction"] == 1, do: "Correct", else: "Incorrect"}
              </h2>
              <div class="flashcard-feedback">
                <p>{keep_punctuation_with_word(@correction["feedback"])}</p>
                <div class="expected">
                  <strong>Réponse attendue</strong>
                  <p class="expected-answer">{keep_punctuation_with_word(@correction["expected"])}</p>
                </div>
              </div>
            </div>
            <footer class="flashcard-actions" id="flashcard-next-actions">
              <button
                :if={@correction}
                id="next-card"
                class="button primary"
                type="button"
                phx-click="next_card"
                phx-value-id={@question["id"]}
                data-has-next={to_string(@remaining > 0)}
              >
                {if @exam.card_index + 1 == length(@exam.questions),
                  do: "Voir mon résultat",
                  else: "Question suivante"}
                <.icon name="arrow" />
              </button>
            </footer>
          </div>
        </div>
        <div
          id="flashcard-stack-overlay"
          phx-hook="FlashcardStack"
          phx-update="ignore"
          aria-hidden="true"
        />
      </div>
      {render_slot(@footer)}
    </section>
    """
  end

  defp keep_punctuation_with_word(nil), do: ""

  defp keep_punctuation_with_word(text) do
    text = Regex.replace(~r/\s+([?!;:»])/u, text, "\u00A0\\1")
    Regex.replace(~r/«\s+/u, text, "«\u00A0")
  end
end

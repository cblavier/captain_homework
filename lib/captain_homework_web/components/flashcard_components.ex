defmodule CaptainHomeworkWeb.FlashcardComponents do
  use Phoenix.Component
  import CaptainHomeworkWeb.CoreComponents
  alias CaptainHomework.Exams.Flashcards

  def flashcard_active?(%{format: "flashcard", status: status}),
    do: status in ["in_progress", "grading"]

  def flashcard_active?(_), do: false

  attr :exam, :map, required: true
  attr :answers, :map, required: true
  attr :close_path, :string, required: true
  attr :error, :string, default: nil

  def flashcard(assigns) do
    question = Flashcards.current(assigns.exam)
    correction = assigns.exam.corrections[question["id"]]

    assigns =
      assign(assigns,
        question: question,
        correction: correction,
        flipped: assigns.exam.status == "grading" or not is_nil(correction),
        grading: assigns.exam.status == "grading",
        form: to_form(%{"answers" => assigns.answers})
      )

    ~H"""
    <section id="flashcard-session" aria-label="Révision par flashcards">
      <div id="flashcard-viewport" phx-hook="FlashcardViewport" phx-update="ignore" hidden />
      <header class="flashcard-header">
        <.link
          navigate={@close_path}
          id="close-flashcards"
          class="icon-button"
          aria-label="Fermer les flashcards"
        >
          <.icon name="close" />
        </.link>
        <div class="flashcard-progress" id="flashcard-progress">
          <span>Carte {@exam.card_index + 1} / {length(@exam.questions)}</span>
          <progress
            id="flashcard-progress-bar"
            value={map_size(@exam.corrections)}
            max={length(@exam.questions)}
            aria-label="Cartes corrigées"
            aria-valuetext={"#{map_size(@exam.corrections)} cartes corrigées sur #{length(@exam.questions)}"}
          />
        </div>
      </header>
      <div class="flashcard-scene" id={"flashcard-#{@question["id"]}"}>
        <div class={["flashcard-inner", @flipped && "is-flipped", @grading && "is-grading"]}>
          <div
            class="flashcard-face flashcard-front"
            aria-hidden={to_string(@flipped)}
            inert={@flipped}
          >
            <div class="question-meta">
              <span>À toi de jouer</span><span class="points">1 point</span>
            </div>
            <h2 id="flashcard-question">{@question["prompt"]}</h2>
            <p :if={@question["text"] != ""} class="reading-text">{@question["text"]}</p>
            <.diagram :if={@question["type"] == "diagram"} question={@question} />
            <.form
              for={@form}
              id="flashcard-answer"
              phx-change="save_answers"
              phx-submit="validate_card"
            >
              <input type="hidden" name="question_id" value={@question["id"]} />
              <fieldset disabled={@grading or @flipped}>
                <div :if={@question["type"] == "mcq"} class="options">
                  <label
                    :for={{option, index} <- Enum.with_index(@question["options"])}
                    class={["option", @answers[@question["id"]] == option && "selected"]}
                  >
                    <input
                      type="radio"
                      id={"flashcard-option-#{index}"}
                      name={"answers[#{@question["id"]}]"}
                      value={option}
                      checked={@answers[@question["id"]] == option}
                    />
                    <span>{option}</span>
                  </label>
                </div>
                <div :if={@question["type"] in ["cloze", "diagram"]} class="slot-inputs">
                  <div :for={{slot, index} <- Enum.with_index(@question["slots"])}>
                    <label for={"flashcard-slot-#{index}"}>{slot}</label>
                    <input
                      id={"flashcard-slot-#{index}"}
                      name={"answers[#{@question["id"]}][#{slot}]"}
                      value={slot_value(@answers[@question["id"]], slot)}
                      maxlength="2000"
                      autocomplete="off"
                      phx-debounce="300"
                    />
                  </div>
                </div>
                <div :if={@question["type"] not in ["mcq", "cloze", "diagram"]}>
                  <label for="flashcard-response">Ta réponse</label>
                  <textarea
                    id="flashcard-response"
                    name={"answers[#{@question["id"]}]"}
                    rows="3"
                    maxlength="12000"
                    phx-debounce="300"
                  >{@answers[@question["id"]] || ""}</textarea>
                </div>
              </fieldset>
            </.form>
          </div>
          <div
            class="flashcard-face flashcard-back"
            aria-hidden={to_string(not @flipped)}
            inert={not @flipped}
          >
            <div
              :if={is_nil(@correction)}
              id="flashcard-grading"
              class="flashcard-loading"
              role="status"
              aria-busy="true"
              aria-label="Correction en cours"
            >
              <span class="spinner" aria-hidden="true" />
            </div>
            <div :if={@correction} id="flashcard-correction" role="status">
              <div class="question-meta">
                <span>Correction</span><strong class="points">{score(@correction["points"])} / 1</strong>
              </div>
              <h2>{@question["prompt"]}</h2>
              <div class="student-answer">
                <strong>Ta réponse</strong>
                <p>{answer_text(@answers[@question["id"]])}</p>
              </div>
              <div class={["correction", @correction["fraction"] == 1 && "correction-correct"]}>
                <p>{@correction["feedback"]}</p>
                <div class="expected">
                  <strong>Réponse attendue</strong>
                  <p class="expected-answer">{@correction["expected"]}</p>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
      <footer class="flashcard-actions" id="flashcard-actions">
        <p :if={@error} id="flashcard-error" class="notice error" role="alert">{@error}</p>
        <button
          :if={!@flipped}
          id="validate-card"
          class="button primary"
          type="submit"
          form="flashcard-answer"
        >
          Valider ma réponse
        </button>
        <button
          :if={@correction}
          id="next-card"
          class="button primary"
          type="button"
          phx-click="next_card"
          phx-value-id={@question["id"]}
        >
          {if @exam.card_index + 1 == length(@exam.questions),
            do: "Voir mon résultat",
            else: "Carte suivante"}
          <.icon name="arrow" />
        </button>
      </footer>
    </section>
    """
  end

  defp slot_value(answer, slot) when is_map(answer), do: answer[slot] || ""
  defp slot_value(_, _), do: ""

  defp answer_text(answer) when is_map(answer),
    do: Enum.map_join(answer, " · ", fn {key, value} -> "#{key} : #{value}" end)

  defp answer_text(answer) when answer in [nil, ""], do: "Aucune réponse"
  defp answer_text(answer), do: answer

  defp score(value),
    do: value |> to_string() |> String.replace(".0", "") |> String.replace(".", ",")
end

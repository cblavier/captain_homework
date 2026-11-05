defmodule CaptainHomeworkWeb.GenerationComponents do
  use Phoenix.Component
  alias CaptainHomework.Exams.GenerationHistory
  alias Phoenix.LiveView.JS
  import CaptainHomeworkWeb.CoreComponents, only: [icon: 1]

  attr :questions, :any, required: true
  attr :id, :string, default: "generation-questions"

  def generation_questions(assigns) do
    ~H"""
    <div id={@id} phx-update="stream" class="generation-questions">
      <details
        :for={{dom_id, question} <- @questions}
        id={dom_id}
        class="generation-question"
        data-status={question["status"]}
        phx-mounted={JS.ignore_attributes("open")}
      >
        <summary>
          <span class="generation-question-number">{question["position"]}</span>
          <span class="generation-question-copy">
            <strong>{question["title"]}</strong>
            <span class="generation-question-reason">{reason(question)}</span>
          </span>
          <span class={["generation-question-badge", badge_class(question)]}>
            <span
              :if={question["status"] in ~w(writing repairing checking audio)}
              id={dom_id <> "-spinner"}
              phx-update="ignore"
              class="spinner"
              aria-hidden="true"
            />
            <.icon
              :if={question["status"] not in ~w(writing repairing checking audio)}
              name={status_icon(question["status"])}
            />
            {status_label(question)}
          </span>
          <.icon name="chevron-down" class="generation-question-chevron" />
        </summary>
        <div class="generation-question-detail">
          <div :if={last_rejection(question)} class="generation-question-diagnostic">
            <h3>Pourquoi cette question a-t-elle été revue ?</h3>
            <p>{last_rejection(question)}</p>
          </div>
          <ol class="generation-events" id={dom_id <> "-events"}>
            <li
              :for={{event, index} <- Enum.with_index(question["events"])}
              id={dom_id <> "-event-#{index}"}
              data-status={event["status"]}
            >
              <span class="generation-event-time">{elapsed(event["elapsed_ms"])}</span>
              <.icon name={status_icon(event["status"])} />
              <span>{event["reason"]}</span>
            </li>
          </ol>
          <p :if={question["events"] == []} class="muted">Aucune étape enregistrée pour le moment.</p>
          <details
            :for={{version, index} <- Enum.with_index(question["versions"])}
            id={dom_id <> "-version-#{version["number"]}"}
            class="generation-version"
            open={index > 0 and index == length(question["versions"]) - 1}
            phx-mounted={JS.ignore_attributes("open")}
          >
            <summary>
              Version {version["number"]}<span :if={index > 0}> · {changes(version)}</span>
            </summary>
            <div class={["generation-comparison", index == 0 && "generation-single-version"]}>
              <div :if={index > 0}>
                <h4>Avant</h4>
                <.question_version content={Enum.at(question["versions"], index - 1)["content"]} />
              </div>
              <div>
                <h4>{if index == 0, do: "Version initiale", else: "Après"}</h4>
                <.question_version content={version["content"]} />
              </div>
            </div>
          </details>
        </div>
      </details>
    </div>
    """
  end

  attr :content, :map, required: true

  defp question_version(assigns) do
    ~H"""
    <p :if={@content["prompt"] not in [nil, ""]}>{@content["prompt"]}</p>
    <p :if={@content["text"] not in [nil, ""]}>{@content["text"]}</p>
    <div :if={@content["support_text"] not in [nil, ""]} class="generation-version-support">
      <h4>Document</h4>
      <p>{@content["support_text"]}</p>
    </div>
    <ul :if={is_list(@content["options"]) and @content["options"] != []}>
      <li :for={option <- @content["options"]}>{option}</li>
    </ul>
    """
  end

  defp status_label(entry) do
    if GenerationHistory.corrected?(entry) do
      "Prête · corrigée"
    else
      Map.get(
        %{
          "waiting" => "En attente",
          "writing" => "Rédaction",
          "received" => "Rédigée",
          "checking" => "Vérification",
          "repairing" => "Correction en cours",
          "audio" => "Création audio",
          "rejected" => "Rejetée",
          "ready" => "Prête",
          "blocked" => "Bloquée",
          "interrupted" => "Interrompue"
        },
        entry["status"],
        "En attente"
      )
    end
  end

  defp status_icon("ready"), do: "check"
  defp status_icon(status) when status in ~w(rejected blocked interrupted), do: "warning"
  defp status_icon(status) when status in ~w(repairing writing received), do: "pencil"
  defp status_icon(_), do: "paper"

  defp badge_class(entry) do
    cond do
      GenerationHistory.corrected?(entry) -> "generation-corrected"
      entry["status"] == "ready" -> "generation-ready"
      entry["status"] in ~w(rejected blocked interrupted) -> "generation-failed"
      entry["status"] == "repairing" -> "generation-repairing"
      true -> "generation-pending"
    end
  end

  defp last_rejection(entry),
    do:
      entry["events"]
      |> Enum.reverse()
      |> Enum.find_value(fn event -> if event["status"] == "rejected", do: event["reason"] end)

  defp reason(%{"status" => "repairing"} = entry), do: last_rejection(entry) || entry["reason"]
  defp reason(entry), do: entry["reason"]

  defp elapsed(milliseconds) do
    seconds = div(milliseconds, 1000)

    "#{div(seconds, 60)}:#{seconds |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp changes(version) do
    labels = %{
      "prompt" => "consigne",
      "text" => "texte",
      "support_text" => "document",
      "options" => "choix",
      "points" => "points",
      "rubric" => "barème",
      "answer" => "réponse attendue",
      "image_ids" => "illustrations",
      "audio_script" => "extrait audio"
    }

    Enum.map_join(version["changed"], ", ", &Map.get(labels, &1, &1))
  end
end

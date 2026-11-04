defmodule CaptainHomework.Exams.GenerationHistory do
  @moduledoc "Persistent question states and received revisions, independent of the repair plan."

  @visible_fields ~w(prompt text support_text options)
  @change_fields ~w(prompt text support_text options points rubric answer image_ids audio_script)

  def key(question), do: question["plan_id"] || question["generation_id"] || question["id"]

  def initialize(%{generation_history: [_ | _]} = exam), do: exam

  def initialize(exam) do
    count = max(exam.generation_target || length(exam.questions), 1)

    entries =
      for position <- 1..count do
        question = Enum.at(exam.questions, position - 1)
        id = if question, do: key(question), else: "slot-#{position}"
        entry = new_entry(id, position, question || %{})

        if question,
          do: Map.merge(entry, %{"status" => "ready", "reason" => "Question déjà conservée"}),
          else: entry
      end

    %{exam | generation_history: entries}
  end

  def plan(exam, %{"questions" => slots}) when is_list(slots) do
    previous = Map.new(exam.generation_history, &{&1["id"], &1})
    kept = MapSet.new(exam.questions, &key/1)

    entries =
      slots
      |> Enum.filter(&is_map/1)
      |> Enum.with_index(1)
      |> Enum.map(fn {slot, position} ->
        id = key(slot) || "slot-#{position}"
        entry = Map.get(previous, id, new_entry(id, position, slot))

        entry
        |> Map.put("position", position)
        |> Map.put("title", title(slot, position))
        |> Map.put("type", slot["type"])
        |> then(fn entry ->
          if MapSet.member?(kept, id), do: Map.put(entry, "status", "ready"), else: entry
        end)
      end)

    if entries == [], do: exam, else: %{exam | generation_history: entries}
  end

  def plan(exam, _), do: exam

  # Legacy generation and flashcards have no plan IDs. Reuse only unfilled slots.
  def identify_drafts(exam, drafts) do
    available = Enum.reject(exam.generation_history, &(&1["status"] == "ready"))

    {drafts, _} =
      Enum.map_reduce(drafts, available, fn question, remaining ->
        existing = Enum.find(remaining, &(&1["id"] == key(question)))
        entry = existing || List.first(remaining)

        question =
          if entry && is_nil(question["plan_id"]),
            do: Map.put(question, "generation_id", entry["id"]),
            else: question

        {question, List.delete(remaining, entry)}
      end)

    drafts
  end

  def received(exam, questions) do
    Enum.reduce(questions, exam, fn question, exam ->
      update(exam, key(question), fn entry ->
        snapshot = Map.take(question, @visible_fields)
        fingerprint = digest(Map.take(question, @change_fields))
        versions = entry["versions"]
        previous = List.last(versions)

        if previous && previous["digest"] == fingerprint do
          entry
        else
          changed =
            if previous,
              do: Enum.filter(@change_fields, &(previous["fields"][&1] != digest(question[&1]))),
              else: []

          version = %{
            "number" => length(versions) + 1,
            "content" => snapshot,
            "digest" => fingerprint,
            "fields" => Map.new(@change_fields, &{&1, digest(question[&1])}),
            "changed" => changed
          }

          entry
          |> Map.put("title", title(question, entry["position"]))
          |> Map.put("type", question["type"])
          |> Map.put("versions", versions ++ [version])
          |> event(
            exam,
            "received",
            if(previous, do: "Nouvelle version reçue", else: "Première version reçue")
          )
        end
      end)
    end)
  end

  def transition(exam, questions, status, reason) do
    ids = MapSet.new(questions, fn q -> if is_map(q), do: key(q), else: q end)

    %{
      exam
      | generation_history:
          Enum.map(exam.generation_history, fn entry ->
            if MapSet.member?(ids, entry["id"]),
              do: event(entry, exam, status, reason),
              else: entry
          end)
    }
  end

  def pending(exam, status, reason) do
    ids = for entry <- exam.generation_history, entry["status"] != "ready", do: entry["id"]
    transition(exam, ids, status, reason)
  end

  def rejected(exam, diagnostics) do
    Enum.reduce(diagnostics, exam, fn {id, diagnostic}, exam ->
      reason = if is_map(diagnostic), do: diagnostic["reason"], else: Enum.join(diagnostic, " ")
      transition(exam, [id], "rejected", reason || "La vérification de cette question a échoué.")
    end)
  end

  def accepted(exam, questions),
    do: transition(exam, questions, "ready", "Vérifications réussies · question prête")

  def stopped(exam, reason) do
    %{
      exam
      | generation_history:
          Enum.map(exam.generation_history, fn entry ->
            cond do
              entry["status"] == "ready" ->
                entry

              entry["status"] == "rejected" ->
                event(entry, exam, "blocked", entry["reason"])

              entry["status"] == "blocked" ->
                entry

              entry["status"] == "interrupted" ->
                entry

              entry["status"] == "waiting" ->
                event(
                  entry,
                  exam,
                  "waiting",
                  "Cette étape n’a pas commencé avant l’arrêt de la génération."
                )

              true ->
                event(entry, exam, "interrupted", reason)
            end
          end)
    }
  end

  def entries(exam) do
    Enum.map(exam.generation_history, fn entry ->
      # IDs from model plans are data, never DOM selectors.
      Map.put(entry, :id, "generation-question-#{entry["position"]}")
    end)
  end

  def corrected?(entry) do
    entry["status"] == "ready" and length(entry["versions"]) > 1 and
      Enum.any?(entry["events"], &(&1["status"] == "rejected"))
  end

  defp new_entry(id, position, question) do
    %{
      "id" => id,
      "position" => position,
      "title" => title(question, position),
      "type" => question["type"],
      "status" => "waiting",
      "reason" => "En attente de rédaction",
      "events" => [],
      "versions" => []
    }
  end

  defp title(question, position) do
    Enum.find([question["objective"], question["prompt"]], fn value ->
      is_binary(value) and String.trim(value) != ""
    end) || "Question #{position}"
  end

  defp update(exam, id, fun),
    do: %{
      exam
      | generation_history:
          Enum.map(exam.generation_history, fn entry ->
            if entry["id"] == id, do: fun.(entry), else: entry
          end)
    }

  defp event(entry, exam, status, reason) do
    if entry["status"] == status and entry["reason"] == reason do
      entry
    else
      elapsed =
        if exam.generation_started_at,
          do: max(DateTime.diff(DateTime.utc_now(), exam.generation_started_at, :millisecond), 0),
          else: 0

      event = %{
        "status" => status,
        "reason" => reason,
        "elapsed_ms" => (exam.generation_duration_ms || 0) + elapsed,
        "version" => length(entry["versions"])
      }

      entry
      |> Map.put("status", status)
      |> Map.put("reason", reason)
      |> Map.update!("events", &(&1 ++ [event]))
    end
  end

  defp digest(value),
    do:
      value
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
end

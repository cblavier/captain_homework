defmodule CaptainHomework.Repo.Migrations.RetireSubjectQuestionConfiguration do
  use Ecto.Migration

  # One-time conversion of historical controls. No question-name inference remains
  # in the application: new controls select explicit catalogue definitions.
  def up do
    exams =
      repo().query!(
        "SELECT e.id, l.subject, e.questions FROM exams e JOIN lessons l ON l.id = e.lesson_id"
      ).rows

    if exams != [] do
      seed_definitions()

      definitions =
        repo().query!(
          "SELECT id, name, subjects, modes, response_kind, instruction_kind, instruction, content_kind, content_presence, help_classic, help_flashcard, work_duration, example, revision FROM question_definitions WHERE deleted_at IS NULL"
        )

      by_name =
        Map.new(definitions.rows, fn row ->
          snapshot = Enum.zip(definitions.columns, row) |> Map.new()

          snapshot =
            Enum.reduce(~w(subjects modes example), snapshot, fn key, data ->
              Map.update!(data, key, &Jason.decode!/1)
            end)

          {snapshot["name"], snapshot}
        end)

      for [exam_id, subject, json] <- exams do
        questions =
          Enum.map(Jason.decode!(json), fn question ->
            if question["definition_id"] do
              question
            else
              name = definition_name(subject, question)
              definition = Map.fetch!(by_name, name)

              unless subject in definition["subjects"],
                do: raise("Type #{name} non applicable à #{subject}")

              repo().query!(
                "INSERT INTO exam_question_definitions (exam_id, definition_id, snapshot) VALUES (?, ?, ?) ON CONFLICT DO NOTHING",
                [exam_id, definition["id"], Jason.encode!(definition)]
              )

              Map.put(question, "definition_id", definition["id"])
            end
          end)

        repo().query!("UPDATE exams SET questions = ? WHERE id = ?", [
          Jason.encode!(questions),
          exam_id
        ])
      end
    end

    alter table(:question_definitions) do
      remove :legacy_ids
    end

    drop table(:question_catalogue_state)
    drop table(:subject_question_settings)
  end

  def down, do: raise("Cette migration remplace définitivement les anciens types de questions.")

  defp seed_definitions do
    fields =
      ~w(name subjects modes response_kind instruction_kind instruction content_kind content_presence help_classic help_flashcard work_duration example)

    now = NaiveDateTime.utc_now() |> NaiveDateTime.to_iso8601()

    definitions =
      File.read!(Application.app_dir(:captain_homework, "priv/repo/question_definitions.json"))
      |> Jason.decode!()

    for definition <- definitions do
      key = String.downcase(definition["name"])

      if repo().query!("SELECT id FROM question_definitions WHERE name_key = ?", [key]).rows == [] do
        values =
          Enum.map(fields, fn field ->
            value = definition[field]
            if field in ~w(subjects modes example), do: Jason.encode!(value), else: value
          end)

        columns = ["id", "name_key", "inserted_at", "updated_at"] ++ fields
        placeholders = Enum.map_join(columns, ",", fn _ -> "?" end)

        repo().query!(
          "INSERT INTO question_definitions (#{Enum.join(columns, ",")}) VALUES (#{placeholders})",
          [Ecto.UUID.generate(), key, now, now] ++ values
        )
      end
    end
  end

  defp definition_name(_, %{"type" => "mcq"}), do: "QCM"
  defp definition_name(_, %{"type" => "cloze"}), do: "Texte à trous"
  defp definition_name(_, %{"type" => "diagram"}), do: "Schéma à compléter"
  defp definition_name(_, %{"type" => "reading"}), do: "Analyse de document"

  defp definition_name("anglais", %{"type" => "definition", "prompt" => prompt}) do
    cond do
      String.contains?(String.downcase(prompt), ["français", "francais"]) ->
        "Traduction vers le français"

      String.contains?(String.downcase(prompt), "anglais") ->
        "Traduction vers l’anglais"

      true ->
        raise "Traduction historique sans langue cible : #{prompt}"
    end
  end

  defp definition_name(_, %{"type" => "definition", "prompt" => prompt}) do
    if String.contains?(String.downcase(prompt), ["défini", "defini"]),
      do: "Définition",
      else: "Réponse courte"
  end

  defp definition_name(_, %{"type" => "long"} = question) do
    if question["response_effort"] == "short" or String.contains?(question["prompt"], "1 ou 2"),
      do: "Réponse courte expliquée",
      else: "Rédaction"
  end

  defp definition_name(subject, question),
    do: raise("Question historique non reconnue : #{subject} / #{question["type"]}")
end

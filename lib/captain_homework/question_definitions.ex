defmodule CaptainHomework.QuestionDefinitions do
  @moduledoc "Catalogue commun, indépendant des profils et des instances de questions."
  import Ecto.Query
  alias CaptainHomework.Repo
  alias CaptainHomework.Study.{QuestionDefinition, ExamQuestionDefinition}

  def change(type \\ %QuestionDefinition{}, attrs \\ %{}),
    do: QuestionDefinition.changeset(type, attrs)

  def list(filters \\ %{}) do
    search = String.downcase(String.trim(filters["search"] || ""))

    Repo.all(from t in QuestionDefinition, where: is_nil(t.deleted_at), order_by: t.name_key)
    |> Enum.filter(fn t ->
      String.contains?(String.downcase(t.name), search) and
        (filters["subject"] in [nil, ""] or filters["subject"] in t.subjects) and
        (filters["mode"] in [nil, ""] or filters["mode"] in t.modes)
    end)
  end

  def get!(id),
    do: Repo.one!(from t in QuestionDefinition, where: t.id == ^id and is_nil(t.deleted_at))

  def save(type, attrs) do
    cs = change(type, attrs)
    cs = if type.id, do: Ecto.Changeset.optimistic_lock(cs, :revision), else: cs

    Repo.transaction(fn ->
      case Repo.insert_or_update(cs) do
        {:ok, type} ->
          type

        {:error, cs} ->
          Repo.rollback(cs)
      end
    end)
  rescue
    Ecto.StaleEntryError ->
      {:error,
       Ecto.Changeset.add_error(
         change(type, attrs),
         :name,
         "Ce type a été modifié ailleurs. Recharge la page."
       )}
  end

  def delete(id) do
    Repo.transaction(fn ->
      type = get!(id)

      if used?(type) do
        type
        |> Ecto.Changeset.change(deleted_at: DateTime.utc_now())
        |> Ecto.Changeset.optimistic_lock(:revision)
        |> Repo.update!()
      else
        Repo.delete!(type)
      end
    end)
  rescue
    Ecto.NoResultsError -> {:error, :not_found}
    Ecto.StaleEntryError -> {:error, :stale}
  end

  def used?(definition),
    do: Repo.exists?(from r in ExamQuestionDefinition, where: r.definition_id == ^definition.id)

  def exam_count(nil), do: 0

  def exam_count(definition_id) do
    Repo.one(
      from r in ExamQuestionDefinition,
        where: r.definition_id == ^definition_id,
        select: count(r.exam_id, :distinct)
    )
  end

  def available(subject), do: list(%{"subject" => subject})

  def resolve(subject, ids) do
    available = available(subject)

    if is_list(ids) and ids != [] and
         Enum.all?(ids, fn id -> Enum.any?(available, &(&1.id == id)) end),
       do: {:ok, Enum.filter(available, &(&1.id in ids))},
       else: {:error, :invalid_types}
  end

  def mode_allowed?(definition, mode),
    do: mode in definition.modes and (definition.response_kind != "photo" or mode == "classic")

  def generation_supported?(definition),
    do: engine_format(definition) in CaptainHomework.ResponseFormats.ids()

  def formats(definitions), do: definitions |> Enum.map(&engine_format/1) |> Enum.uniq()

  def engine_format(%{content_kind: "audio", response_kind: "short_text"}), do: "listening"
  def engine_format(%{content_kind: "audio"}), do: nil

  def engine_format(type) do
    case type.response_kind do
      "ordering" -> "ordering"
      "photo" -> "photo"
      "short_text" -> "definition"
      "single_choice" -> "mcq"
      "cloze" -> "cloze"
      "legends" -> "diagram"
      "long_text" -> if(type.content_kind == "document", do: "reading", else: "long")
      _ -> nil
    end
  end

  def snapshot(type) do
    type
    |> Map.from_struct()
    |> Map.drop([:__meta__, :inserted_at, :updated_at, :deleted_at, :name_key])
    |> Jason.encode!()
    |> Jason.decode!()
  end

  def attach!(exam, types) do
    for t <- types do
      Repo.insert!(%ExamQuestionDefinition{
        exam_id: exam.id,
        definition_id: t.id,
        snapshot: snapshot(t)
      })
    end

    exam
  end

  def for_exam(exam) do
    Repo.all(from r in ExamQuestionDefinition, where: r.exam_id == ^exam.id)
    |> Enum.map(fn reference ->
      fields =
        for field <- QuestionDefinition.__schema__(:fields),
            Map.has_key?(reference.snapshot, Atom.to_string(field)),
            into: %{},
            do: {field, reference.snapshot[Atom.to_string(field)]}

      struct(QuestionDefinition, fields)
    end)
  end

  def instructions(types, subject \\ nil) do
    Enum.map_join(types, "\n", fn t ->
      "Type #{t.name} : format #{engine_format(t)}, consigne #{t.instruction_kind} : #{t.instruction}; contenu #{t.content_kind} #{t.content_presence}; durée de travail #{t.work_duration} (≈ #{CaptainHomework.WorkDuration.minutes(t.work_duration)} min). " <>
        "Une consigne dynamique doit devenir une demande précise adaptée au document, pas le libellé générique du type. " <>
        "Un contenu requis peut être fourni par un document original lisible recadré : ne remplis pas text avec une paraphrase de l'image. " <>
        "Les aides de saisie et descriptions OCR internes ne sont pas le contenu à montrer. Ne révèle jamais la réponse attendue dans l’énoncé."
    end)
    |> CaptainHomework.QuestionTemplates.render(subject)
  end

  def seed! do
    Repo.transaction(fn ->
      for attrs <- CaptainHomework.QuestionDefinitionSeeds.all() do
        key = String.downcase(attrs["name"])

        unless Repo.exists?(from t in QuestionDefinition, where: t.name_key == ^key) do
          %QuestionDefinition{example: attrs["example"]}
          |> change(Map.delete(attrs, "example"))
          |> Repo.insert!()
        end
      end
    end)
  end
end

defmodule CaptainHomework.SubjectQuestionTypes do
  alias CaptainHomework.{QuestionTypes, QuestionTypeCatalogue, Repo, Study, WorkDuration}
  alias CaptainHomework.Study.SubjectQuestionSettings
  import Ecto.Changeset

  def defaults do
    Enum.map(QuestionTypes.options(), fn {id, label, description} ->
      WorkDuration.with_default(%{
        "id" => id,
        "label" => label,
        "description" => description,
        "format" => id
      })
    end)
  end

  def list(profile_id, subject) do
    Study.subject!(subject)

    case Repo.get_by(SubjectQuestionSettings, profile_id: profile_id, subject: subject) do
      nil -> defaults()
      settings -> Enum.map(settings.types, &WorkDuration.with_default/1)
    end
  end

  def change_type(attrs \\ %{}) do
    {%{work_duration: "medium"}, %{label: :string, description: :string, work_duration: :string}}
    |> cast(attrs, [:label, :description, :work_duration])
    |> update_change(:label, &String.trim/1)
    |> update_change(:description, &String.trim/1)
    |> validate_required([:label, :description, :work_duration],
      message: "Ce champ est obligatoire."
    )
    |> validate_inclusion(:work_duration, WorkDuration.values())
    |> validate_length(:label, max: 80, message: "80 caractères maximum.")
    |> validate_length(:description, max: 1000, message: "1 000 caractères maximum.")
  end

  def add(profile_id, subject, attrs) do
    changeset = change_type(attrs)

    with {:ok, values} <- apply_action(changeset, :insert),
         :ok <- unique_label(profile_id, subject, values.label, changeset),
         {:ok, format} <- infer_format(values.label, values.description) do
      mutate(profile_id, subject, fn types ->
        if Enum.any?(types, &(String.downcase(&1["label"]) == String.downcase(values.label))) do
          Repo.rollback(add_error(changeset, :label, "Ce nom existe déjà."))
        end

        types ++
          [
            %{
              "id" => Ecto.UUID.generate(),
              "label" => values.label,
              "description" => values.description,
              "format" => format,
              "format_inferred" => true,
              "work_duration" => values.work_duration
            }
          ]
      end)
    else
      {:error, %Ecto.Changeset{} = invalid} ->
        {:error, invalid}

      {:error, _} ->
        {:error, add_error(changeset, :label, "Le format n’a pas pu être déterminé. Réessaie.")}
    end
  end

  @doc "Installe le catalogue par matière sans écraser les types ou réglages existants."
  def seed_catalogue(profile_id, subject) do
    catalogue = QuestionTypeCatalogue.for_subject(subject)

    mutate(
      profile_id,
      subject,
      fn types ->
        existing = Map.new(types, &{String.downcase(&1["label"]), &1})
        labels = MapSet.new(catalogue, &String.downcase(&1["label"]))

        Enum.map(catalogue, fn type ->
          Map.merge(type, Map.get(existing, String.downcase(type["label"]), %{}))
        end) ++ Enum.reject(types, &MapSet.member?(labels, String.downcase(&1["label"])))
      end,
      []
    )
  end

  defp unique_label(profile_id, subject, label, changeset) do
    if Enum.any?(
         list(profile_id, subject),
         &(String.downcase(&1["label"]) == String.downcase(label))
       ), do: {:error, add_error(changeset, :label, "Ce nom existe déjà.")}, else: :ok
  end

  def delete(profile_id, subject, id) do
    mutate(profile_id, subject, &Enum.reject(&1, fn type -> type["id"] == id end))
  end

  def update_duration(profile_id, subject, id, duration) do
    if duration in WorkDuration.values() do
      mutate(profile_id, subject, fn types ->
        unless Enum.any?(types, &(&1["id"] == id)), do: Repo.rollback(:not_found)

        Enum.map(types, fn type ->
          if type["id"] == id, do: Map.put(type, "work_duration", duration), else: type
        end)
      end)
    else
      {:error, :invalid_duration}
    end
  end

  def resolve(profile_id, subject, ids) do
    types = list(profile_id, subject)
    available_ids = Enum.map(types, & &1["id"])

    if is_list(ids) and ids != [] and Enum.all?(ids, &(&1 in available_ids)) do
      selected = Enum.filter(types, &(&1["id"] in ids))
      resolve_formats(profile_id, subject, selected)
    else
      {:error, "Choisis au moins un type disponible dans les paramètres de cette matière."}
    end
  end

  def formats(types) do
    types
    |> Enum.flat_map(fn type ->
      if type["id"] in QuestionTypes.ids(), do: [type["id"]], else: [type["format"] || "long"]
    end)
    |> Enum.uniq()
  end

  defp resolve_formats(profile_id, subject, selected) do
    Enum.reduce_while(selected, {:ok, []}, fn type, {:ok, resolved} ->
      if type["id"] in QuestionTypes.ids() or
           (type["format_inferred"] == true and type["format"] in QuestionTypes.ids()) do
        {:cont, {:ok, resolved ++ [type]}}
      else
        case infer_format(type["label"], type["description"]) do
          {:ok, format} ->
            updated = Map.merge(type, %{"format" => format, "format_inferred" => true})

            with {:ok, _} <-
                   mutate(profile_id, subject, fn types ->
                     Enum.map(types, &if(&1["id"] == type["id"], do: updated, else: &1))
                   end) do
              {:cont, {:ok, resolved ++ [updated]}}
            else
              _ -> {:halt, {:error, "Le format du type de question n’a pas pu être enregistré."}}
            end

          _ ->
            {:halt,
             {:error, "Le format du type de question n’a pas pu être déterminé. Réessaie."}}
        end
      end
    end)
  end

  defp infer_format(label, description) do
    provider = CaptainHomework.AI.provider()

    if Code.ensure_loaded?(provider) and function_exported?(provider, :infer_response_format, 2) do
      with {:ok, format} <- provider.infer_response_format(label, description),
           true <- format in QuestionTypes.ids() do
        {:ok, format}
      else
        _ -> {:error, :invalid_format}
      end
    else
      # Providers without inference (including deterministic test providers) use written answers.
      {:ok, "long"}
    end
  end

  def instructions(types) do
    entries =
      Enum.map_join(types, "\n", fn type ->
        "- #{type["label"]} (format #{type["format"] || type["id"]}) : #{type["description"]}"
      end)

    """
    Types de questions sélectionnés pour cette matière :
    #{entries}
    Utilise exclusivement ces types pédagogiques et leurs consignes.
    Le format a été déduit une fois du nom et de la consigne ; respecte cette association stable.
    Par exemple, un calcul mental attend une réponse brève (definition), un QCM utilise mcq,
    un texte à trous cloze, une compréhension de document reading, une explication rédigée long.
    Les formats JSON disponibles sont des outils de rendu, pas des types pédagogiques supplémentaires
    autorisés : ne crée jamais une question d'un type pédagogique non sélectionné.
    Les noms personnalisés ne sont pas des formats JSON : choisis un format technique compatible.
    Le format ne détermine pas la longueur de la réponse : respecte aussi l'effort prévu par le plan.
    """
  end

  defp mutate(profile_id, subject, fun, initial_types \\ defaults()) do
    Study.subject!(subject)

    Repo.transaction(fn ->
      Repo.insert!(
        %SubjectQuestionSettings{profile_id: profile_id, subject: subject, types: initial_types},
        on_conflict: :nothing,
        conflict_target: [:profile_id, :subject]
      )

      settings = Repo.get_by!(SubjectQuestionSettings, profile_id: profile_id, subject: subject)
      types = settings.types |> Enum.map(&WorkDuration.with_default/1) |> fun.()
      settings |> change(types: types) |> Repo.update!()
    end)
  end
end

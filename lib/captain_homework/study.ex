defmodule CaptainHomework.Study do
  import Ecto.Query
  alias CaptainHomework.Repo
  alias CaptainHomework.Study.{Profile, Lesson, Page, Exam}

  @subjects [
    %{id: "anglais", name: "Anglais", icon: "language", color: "blue"},
    %{id: "espagnol", name: "Espagnol", icon: "language", color: "orange"},
    %{id: "francais", name: "Français", icon: "book", color: "pink"},
    %{id: "histoire-geo", name: "Histoire-Géographie", icon: "globe", color: "orange"},
    %{id: "latin", name: "Latin", icon: "book", color: "purple"},
    %{id: "mathematiques", name: "Mathématiques", icon: "math", color: "purple"},
    %{id: "physique-chimie", name: "Physique-Chimie", icon: "math", color: "blue"},
    %{id: "svt", name: "SVT", icon: "leaf", color: "green"},
    %{id: "technologie", name: "Technologie", icon: "hero-cog-6-tooth", color: "blue"}
  ]
  def subjects, do: @subjects
  def subject_ids, do: Enum.map(@subjects, & &1.id)

  def enabled_subjects(profile), do: Enum.reject(@subjects, &(&1.id in profile.disabled_subjects))

  def save_subjects(profile, enabled_ids) when is_list(enabled_ids) do
    if Enum.all?(enabled_ids, &(&1 in subject_ids())) do
      profile
      |> Ecto.Changeset.change(disabled_subjects: subject_ids() -- enabled_ids)
      |> Repo.update()
    else
      {:error, :invalid_subjects}
    end
  end

  def save_subjects(_profile, _enabled_ids), do: {:error, :invalid_subjects}

  def subject!(id),
    do: Enum.find(@subjects, &(&1.id == id)) || raise(Ecto.NoResultsError, queryable: Lesson)

  def profiles do
    {:ok, profiles} =
      Repo.transaction(fn ->
        Enum.map(CaptainHomework.Family.members(), &sync_profile/1)
      end)

    profiles
  end

  def get_profile(id), do: if(valid_id?(id), do: Enum.find(profiles(), &(&1.id == id)))

  defp sync_profile(member) do
    profile = Repo.get_by(Profile, environment_key: member.key) || legacy_profile(member.name)

    profile =
      case profile do
        nil ->
          %Profile{environment_key: member.key}
          |> Profile.changeset(%{name: member.name})
          |> Repo.insert!(on_conflict: :nothing, conflict_target: :environment_key)

          Repo.get_by!(Profile, environment_key: member.key)

        profile ->
          profile
          |> Profile.changeset(%{name: member.name})
          |> Ecto.Changeset.put_change(:environment_key, member.key)
          |> Repo.update!()
      end

    %{profile | avatar: member.avatar, theme: member.theme}
  end

  defp legacy_profile(name) do
    matches =
      Repo.all(from p in Profile, where: is_nil(p.environment_key))
      |> Enum.filter(
        &(CaptainHomework.Family.normalize(&1.name) == CaptainHomework.Family.normalize(name))
      )

    case matches do
      [] ->
        nil

      [profile] ->
        profile

      _ ->
        raise "Multiple existing profiles match a configured family member; resolve duplicates before linking"
    end
  end

  def valid_id?(id), do: match?({:ok, _}, Ecto.UUID.cast(id))

  def today do
    # Calendar date in metropolitan France, including summer time.
    now = DateTime.utc_now()
    date = DateTime.to_date(now)

    last_sunday = fn month ->
      last = Date.end_of_month(Date.new!(date.year, month, 1))
      Date.add(last, -rem(Date.day_of_week(last), 7))
    end

    summer_start = DateTime.new!(last_sunday.(3), ~T[01:00:00], "Etc/UTC")
    summer_end = DateTime.new!(last_sunday.(10), ~T[01:00:00], "Etc/UTC")

    hours =
      if DateTime.compare(now, summer_start) != :lt and DateTime.compare(now, summer_end) == :lt,
        do: 2,
        else: 1

    now |> DateTime.add(hours * 3600) |> DateTime.to_date()
  end

  def create_lesson(profile, attrs) do
    %Lesson{profile_id: profile.id}
    |> Lesson.changeset(Map.put(attrs, "date", today()))
    |> Repo.insert()
  end

  def lessons(profile_id, subject) do
    Repo.all(
      from l in Lesson,
        where: l.profile_id == ^profile_id and l.subject == ^subject,
        order_by: [desc: l.inserted_at],
        preload: [:pages, :exams]
    )
  end

  def counts(profile_id) do
    Repo.all(
      from l in Lesson,
        where: l.profile_id == ^profile_id,
        group_by: l.subject,
        select: {l.subject, count(l.id)}
    )
    |> Map.new()
  end

  def get_lesson!(profile_id, id) do
    if not valid_id?(id), do: raise(Ecto.NoResultsError, queryable: Lesson)

    Repo.one!(from l in Lesson, where: l.id == ^id and l.profile_id == ^profile_id)
    |> Repo.preload(
      resources: from(r in CaptainHomework.Study.Resource, order_by: [r.inserted_at, r.id]),
      pages: from(p in Page, order_by: [p.position, p.inserted_at, p.id]),
      exams: from(e in Exam, order_by: [desc: e.inserted_at])
    )
  end

  def get_exam!(profile_id, id) do
    if not valid_id?(id), do: raise(Ecto.NoResultsError, queryable: Exam)

    Repo.one!(
      from e in Exam,
        join: l in assoc(e, :lesson),
        where: e.id == ^id and l.profile_id == ^profile_id,
        preload: [lesson: l]
    )
  end

  def exam_deletable?(exam),
    do: is_nil(exam.submitted_at) and exam.status not in ["grading", "completed"]

  def delete_exam(profile_id, id) do
    exam = get_exam!(profile_id, id)

    {count, _} =
      Repo.delete_all(
        from e in Exam,
          where:
            e.id == ^exam.id and is_nil(e.submitted_at) and
              e.status not in ["grading", "completed"]
      )

    if count == 1 do
      CaptainHomework.Exams.Illustrations.delete_exam_images(exam)
      {:ok, exam}
    else
      {:error, :already_submitted}
    end
  end

  def delete_lesson(profile_id, id) do
    lesson = get_lesson!(profile_id, id)

    with {:ok, lesson} <- Repo.delete(lesson) do
      Enum.each(lesson.pages, &File.rm(CaptainHomework.Uploads.path(&1.storage_key)))

      Enum.each(lesson.resources, fn resource ->
        if resource.storage_key, do: File.rm(CaptainHomework.Uploads.path(resource.storage_key))
      end)

      Enum.each(lesson.exams, &CaptainHomework.Exams.Illustrations.delete_exam_images/1)
      {:ok, lesson}
    end
  end

  def get_page!(profile_id, id) do
    if not valid_id?(id), do: raise(Ecto.NoResultsError, queryable: Page)

    Repo.one!(
      from p in Page,
        join: l in assoc(p, :lesson),
        where: p.id == ^id and l.profile_id == ^profile_id
    )
  end

  def add_page(lesson, attrs) do
    Repo.transaction(fn ->
      changeset = Page.changeset(%Page{lesson_id: lesson.id}, attrs)
      kind = Ecto.Changeset.get_field(changeset, :kind)

      last =
        Repo.one(
          from p in Page,
            where: p.lesson_id == ^lesson.id and p.kind == ^kind,
            select: max(p.position)
        )

      changeset = Ecto.Changeset.put_change(changeset, :position, (last || -1) + 1)

      case Repo.insert(changeset) do
        {:ok, page} -> page
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def move_page(profile_id, lesson_id, page_id, direction)
      when direction in ["previous", "next"] do
    Repo.transaction(fn ->
      lesson = get_lesson!(profile_id, lesson_id)
      selected = Enum.find(lesson.pages, &(&1.id == page_id))
      if is_nil(selected), do: Repo.rollback(:not_found)
      pages = Enum.filter(lesson.pages, &(&1.kind == selected.kind))
      index = Enum.find_index(pages, &(&1.id == page_id))
      if is_nil(index), do: Repo.rollback(:not_found)
      target = index + if(direction == "previous", do: -1, else: 1)

      if target >= 0 and target < length(pages) do
        page = Enum.at(pages, index)
        neighbor = Enum.at(pages, target)
        pages = pages |> List.replace_at(index, neighbor) |> List.replace_at(target, page)

        pages
        |> Enum.with_index()
        |> Enum.each(fn {page, position} ->
          page |> Ecto.Changeset.change(position: position) |> Repo.update!()
        end)
      end
    end)
  end

  def update_page(page, text),
    do: page |> Page.changeset(%{text: text, status: "ready", error: nil}) |> Repo.update()

  def delete_page(page) do
    with {:ok, page} <- Repo.delete(page) do
      File.rm(CaptainHomework.Uploads.path(page.storage_key))
      {:ok, page}
    end
  end

  def default_instructions, do: CaptainHomework.Settings.instructions()

  def builtin_instructions do
    """
    S’inspirer si possible du modèle de contrôle d’exemple.
    Produire une liste de questions variée, de types différents, correspondant au contenu des leçons.
    Les textes de compréhension peuvent apporter des compléments à la leçon : les réponses doivent alors figurer dans le texte.
    Varier les formes : définitions, QCM, textes à trous, compréhension de texte, réponses rédigées et schémas à légender.
    La variété n’impose jamais de produire un schéma : privilégier un exercice simple et clair lorsqu’un dessin n’apporte aucune information utile.
    Chaque exercice doit être compréhensible et résoluble à partir des connaissances de la leçon et des éléments réellement affichés dans la question. Fournir tous les documents, événements, choix et correspondances nécessaires ; ne jamais renvoyer à une illustration ou une liste absente.
    Pour une chronologie, donner dans l’énoncé les événements à classer, chacun associé à un numéro, puis demander une réponse rédigée contenant les numéros du plus ancien au plus récent. Ne pas utiliser un schéma de cases numérotées pour cet exercice.
    Réserver les schémas à légender aux dessins dont les formes et la disposition permettent réellement d’identifier les éléments étudiés. Des cases contenant seulement 1, 2, 3, 4 ne constituent pas un schéma exploitable. Si le dessin ne peut pas être représenté clairement, choisir un autre type de question.
    Interdire les listes de définitions déguisées en schémas : disposer des numéros dans des ovales ou rectangles, même accompagnés de définitions dans l’énoncé, n’est pas un exercice visuel. Si supprimer le dessin ne change rien à la résolution, supprimer le schéma et utiliser des définitions ou un texte à trous.
    Pour plusieurs définitions à compléter, placer un trou numéroté après chaque définition et demander explicitement de compléter toutes les définitions. Pour une seule définition, ne présenter que cette définition et un seul champ de réponse.
    Préciser ce qui est attendu dans chaque réponse : un mot, une explication ou une suite de numéros. Pour un schéma, demander le nom de chaque élément repéré, et non de recopier les numéros déjà visibles.
    Faire correspondre exactement la consigne, le nombre de réponses et le barème. Ne jamais demander seulement le numéro 1 si cinq champs sont affichés. La correction doit couvrir tous les champs demandés, sans en ajouter.
    Avant de rendre le contrôle, vérifier chaque exercice du point de vue de l’élève, sans consulter la correction : les informations nécessaires sont-elles présentes et la consigne est-elle cohérente avec le mode de réponse ? Reformuler ou remplacer toute question ambiguë ou incomplète sans révéler sa réponse.
    Autoriser la saisie des réponses rédigées par photo avec reconnaissance du texte.
    Donner la correction uniquement à la fin, en rouge, avec une note totale sur 20, une note par question et les réponses attendues.
    Accorder des points partiels (25 %, 50 % ou 75 %) aux réponses partiellement correctes.
    """
    |> String.trim()
  end

  def save_answers(profile_id, exam_id, answers) when is_map(answers) do
    exam = get_exam!(profile_id, exam_id)
    answers = sanitize_answers(exam, answers)

    case Repo.update_all(from(e in Exam, where: e.id == ^exam.id and e.status == "in_progress"),
           set: [answers: answers, updated_at: DateTime.utc_now()]
         ) do
      {1, _} -> {:ok, %{exam | answers: answers}}
      _ -> {:error, :already_submitted}
    end
  end

  def sanitize_answers(exam, answers) do
    Map.new(exam.questions, fn q ->
      value = answers[q["id"]]

      clean =
        cond do
          is_binary(value) ->
            String.slice(value, 0, 12_000)

          is_map(value) ->
            value
            |> Enum.take(30)
            |> Map.new(fn {k, v} ->
              {String.slice(to_string(k), 0, 60),
               if(is_binary(v), do: String.slice(v, 0, 2000), else: "")}
            end)

          true ->
            ""
        end

      {q["id"], clean}
    end)
  end
end

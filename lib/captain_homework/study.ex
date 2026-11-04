defmodule CaptainHomework.Study do
  import Ecto.Query
  alias CaptainHomework.Repo
  alias CaptainHomework.Study.{Profile, Lesson, Page, Exam}

  @subjects [
    %{id: "anglais", name: "Anglais", icon: "flag-uk", color: "blue"},
    %{id: "espagnol", name: "Espagnol", icon: "flag-es", color: "red"},
    %{id: "francais", name: "Français", icon: "flag-fr", color: "pink"},
    %{
      id: "histoire-geo",
      name: "Histoire-Géographie",
      short_name: "Histoire Géo",
      icon: "globe",
      color: "orange"
    },
    %{id: "latin", name: "Latin", icon: "book", color: "gold"},
    %{
      id: "mathematiques",
      name: "Mathématiques",
      short_name: "Maths",
      icon: "math",
      color: "purple"
    },
    %{
      id: "physique-chimie",
      name: "Physique - Chimie",
      short_name: "Phys-Chim",
      icon: "flask",
      color: "teal"
    },
    %{
      id: "svt",
      name: "Science de la Vie de la Terre",
      short_name: "SVT",
      icon: "leaf",
      color: "green"
    },
    %{
      id: "technologie",
      name: "Technologie",
      short_name: "Techno",
      icon: "hero-cog-6-tooth",
      color: "slate"
    }
  ]
  def subject_short_name(subject), do: Map.get(subject, :short_name, subject.name)

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

    %{
      profile
      | avatar: member.avatar,
        theme: member.theme,
        school_name: member.school_name,
        class_name: member.class_name
    }
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

  def exam_counts(profile_id) do
    Repo.all(
      from e in Exam,
        join: l in assoc(e, :lesson),
        where: l.profile_id == ^profile_id and is_nil(e.exam_share_id),
        group_by: l.subject,
        select: {l.subject, count(e.id)}
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

  def get_exam!({:shared, _, _} = scope, id),
    do: CaptainHomework.ExamShares.get_exam!(scope, id)

  def get_exam!(profile_id, id) do
    if not valid_id?(id), do: raise(Ecto.NoResultsError, queryable: Exam)

    Repo.one!(
      from e in Exam,
        join: l in assoc(e, :lesson),
        where: e.id == ^id and l.profile_id == ^profile_id and is_nil(e.exam_share_id),
        preload: [lesson: l]
    )
  end

  def exam_deletable?(exam),
    do: exam.status == "completed" or (is_nil(exam.submitted_at) and exam.status != "grading")

  def delete_exam(profile_id, id) do
    exam = get_exam!(profile_id, id)
    shared_attempts = CaptainHomework.ExamShares.attempts_for_exam(exam.id)

    {count, _} =
      Repo.delete_all(
        from e in Exam,
          where:
            e.id == ^exam.id and
              (e.status == "completed" or (is_nil(e.submitted_at) and e.status != "grading"))
      )

    if count == 1 do
      CaptainHomework.Exams.Illustrations.delete_exam_images(exam)
      CaptainHomework.Exams.PhotoAnswers.delete_files(exam)
      Enum.each(shared_attempts, &CaptainHomework.Exams.PhotoAnswers.delete_files/1)
      {:ok, exam}
    else
      {:error, :already_submitted}
    end
  end

  def delete_lesson(profile_id, id) do
    lesson = get_lesson!(profile_id, id)

    pages = from p in Page, select: p.lesson_id
    exams = from e in Exam, select: e.lesson_id
    resources = from r in CaptainHomework.Study.Resource, select: r.lesson_id

    {count, _} =
      Repo.delete_all(
        from l in Lesson,
          where: l.id == ^lesson.id and l.profile_id == ^profile_id,
          where: l.id not in subquery(pages),
          where: l.id not in subquery(exams),
          where: l.id not in subquery(resources)
      )

    if count == 1, do: {:ok, lesson}, else: {:error, :not_empty}
  end

  def lesson_empty?(lesson),
    do: lesson.pages == [] and lesson.exams == [] and lesson.resources == []

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

      if selected.kind == "illustration" do
        resource = Enum.find(lesson.resources, &(&1.id == selected.resource_id))

        if is_nil(resource) or resource.status != "ready" or resource.processing_stage != nil,
          do: Repo.rollback(:unavailable)
      end

      pages =
        Enum.filter(
          lesson.pages,
          &(&1.kind == selected.kind and &1.resource_id == selected.resource_id)
        )

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

  def update_page(page, text) do
    with {:ok, page} <-
           page |> Page.changeset(%{text: text, status: "ready", error: nil}) |> Repo.update() do
      CaptainHomework.Catalogues.schedule(page)
      {:ok, page}
    end
  end

  def delete_page(page) do
    with {:ok, page} <- Repo.delete(page) do
      File.rm(CaptainHomework.Uploads.path(page.storage_key))
      {:ok, page}
    end
  end

  def order_answer(profile_id, exam_id, question_id, action) do
    exam = get_exam!(profile_id, exam_id)
    question = Enum.find(exam.questions, &(&1["id"] == question_id))
    current = CaptainHomework.Exams.Flashcards.current(exam)

    if ((exam.status == "in_progress" and question) && question["type"] == "ordering") and
         (exam.format != "flashcard" or
            ((current && current["id"] == question_id) and
               not Map.has_key?(exam.corrections, question_id))) do
      answer =
        CaptainHomework.Exams.Ordering.update(
          exam.answers[question_id],
          question["options"],
          action
        )

      save_answers(profile_id, exam_id, Map.put(exam.answers, question_id, answer))
    else
      {:error, :unavailable}
    end
  end

  def save_answers(profile_id, exam_id, answers) when is_map(answers) do
    exam = get_exam!(profile_id, exam_id)

    answers =
      if exam.format == "flashcard" do
        question = CaptainHomework.Exams.Flashcards.current(exam)

        if question && not Map.has_key?(exam.corrections, question["id"]),
          do: Map.merge(exam.answers, Map.take(answers, [question["id"]])),
          else: exam.answers
      else
        answers
      end

    answers = sanitize_answers(exam, answers)

    case Repo.update_all(
           from(e in Exam,
             where:
               e.id == ^exam.id and e.status == "in_progress" and e.updated_at == ^exam.updated_at
           ),
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
          q["type"] == "photo" ->
            Map.get(exam.answers, q["id"], "")

          q["type"] == "ordering" ->
            CaptainHomework.Exams.Ordering.normalize(value, q["options"])

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

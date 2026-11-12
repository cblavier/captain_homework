defmodule CaptainHomework.Exams.QuestionRegeneration do
  @moduledoc "Runs a replacement through the normal pipeline without removing the original question."
  import Ecto.Query
  alias CaptainHomework.{Accounts, Exams, QuestionDefinitions, Repo, Study}
  alias CaptainHomework.Study.Exam
  alias CaptainHomework.Exams.{GenerationJobs, Illustrations}

  def states(exam) do
    case exam.regeneration do
      %{"questions" => questions} -> questions
      %{"question_id" => id} = state -> %{id => Map.take(state, ~w(question_id job_id status))}
      _ -> %{}
    end
  end

  def state(exam, id), do: Map.get(states(exam), id, %{})
  def running?(exam), do: Enum.any?(states(exam), fn {_, s} -> s["status"] == "generating" end)

  def pending?(exam),
    do: Enum.any?(states(exam), fn {_, s} -> s["status"] in ~w(generating failed) end)

  def pending?(exam, id), do: state(exam, id)["status"] in ~w(generating failed)

  defp put_state(exam, state) do
    questions = Map.put(states(exam), state["question_id"], state)

    status =
      cond do
        Enum.any?(questions, fn {_, s} -> s["status"] == "generating" end) -> "generating"
        Enum.any?(questions, fn {_, s} -> s["status"] == "failed" end) -> "failed"
        true -> state["status"]
      end

    exam.regeneration
    |> Map.merge(state)
    |> Map.put("questions", questions)
    |> Map.put("status", status)
  end

  def save_instructions(account, profile_id, exam_id, instructions)
      when is_binary(instructions) do
    exam = Study.get_exam!(profile_id, exam_id)

    if Accounts.parent?(account) and
         Accounts.profile_allowed?(account, Study.get_profile(profile_id)) and
         is_nil(exam.exam_share_id) and is_nil(exam.regeneration_source_id) do
      instructions = String.slice(instructions, 0, 8000)

      Repo.update_all(
        from(e in Exam,
          where: e.id == ^exam.id and e.status == "in_progress",
          update: [
            set: [
              regeneration:
                fragment("json_set(?, '$.instructions', ?)", e.regeneration, ^instructions),
              updated_at: ^DateTime.utc_now()
            ]
          ]
        ),
        []
      )
    else
      {:error, :not_allowed}
    end
  end

  def jobs(exam) do
    ids =
      for {_, state} <- states(exam),
          state["status"] in ~w(generating failed),
          id = state["job_id"],
          not is_nil(id),
          do: id

    Repo.all(from e in Exam, where: e.id in ^ids and e.regeneration_source_id == ^exam.id)
  end

  def cancel(account, profile_id, exam_id, job_id) do
    exam = Study.get_exam!(profile_id, exam_id)

    state =
      Enum.find_value(states(exam), fn {_, state} -> if state["job_id"] == job_id, do: state end)

    if (Accounts.parent?(account) and
          Accounts.profile_allowed?(account, Study.get_profile(profile_id)) and
          exam.status == "in_progress" and state) && state["status"] == "failed" do
      state = put_state(exam, Map.put(state, "status", "cancelled"))

      case Repo.update_all(
             from(e in Exam, where: e.id == ^exam.id and e.updated_at == ^exam.updated_at),
             set: [regeneration: state, updated_at: DateTime.utc_now()]
           ) do
        {1, _} ->
          notify(exam.id)
          :ok

        _ ->
          {:error, :stale}
      end
    else
      {:error, :not_allowed}
    end
  end

  def allowed?(account, exam, question_id) do
    Accounts.parent?(account) and is_nil(exam.exam_share_id) and
      is_nil(exam.regeneration_source_id) and exam.status == "in_progress" and
      not pending?(exam, question_id) and
      Enum.any?(exam.questions, &(&1["id"] == question_id)) and
      not Map.has_key?(exam.corrections, question_id)
  end

  def job(exam) do
    if id = exam.regeneration["job_id"] do
      Repo.one(from e in Exam, where: e.id == ^id and e.regeneration_source_id == ^exam.id)
    end
  end

  def start(account, profile_id, exam_id, question_id, type_ids, instructions, opts \\ []) do
    profile = Study.get_profile(profile_id)
    exam = Study.get_exam!(profile_id, exam_id)
    lesson = Study.get_lesson!(profile_id, exam.lesson_id) |> Exams.generation_lesson(exam.format)
    pages = Illustrations.content_pages(lesson)

    examples =
      case CaptainHomework.ReferenceExams.selection(
             profile_id,
             lesson.subject,
             exam.reference_exam_id,
             exam.format
           ) do
        {:ok, _, pages} -> pages
        _ -> []
      end

    with true <-
           Accounts.profile_allowed?(account, profile) and allowed?(account, exam, question_id),
         {:ok, types} <- QuestionDefinitions.resolve(lesson.subject, type_ids),
         true <-
           types != [] and
             Enum.all?(
               types,
               &(QuestionDefinitions.mode_allowed?(&1, exam.format) and
                   QuestionDefinitions.generation_supported?(&1))
             ),
         true <-
           pages != [] and not Illustrations.resources_pending?(lesson) and
             Enum.all?(pages, &(String.trim(&1.text) != "")) do
      now = DateTime.utc_now()

      result =
        Repo.transaction(fn ->
          # Acquire SQLite's write lock before reading the source state.
          Repo.update_all(from(e in Exam, where: e.id == ^exam.id), set: [updated_at: now])
          exam = Repo.get!(Exam, exam.id)
          unless allowed?(account, exam, question_id), do: Repo.rollback(:stale)

          job =
            Repo.insert!(%Exam{
              lesson_id: exam.lesson_id,
              reference_exam_id: exam.reference_exam_id,
              regeneration_source_id: exam.id,
              regeneration: %{"question_id" => question_id},
              format: exam.format,
              instructions: String.slice(String.trim(instructions), 0, 8000),
              question_types: QuestionDefinitions.formats(types),
              status: "generating",
              generation_target: 1,
              generation_started_at: now,
              generation_examples: Enum.map(examples, & &1.id)
            })

          QuestionDefinitions.attach!(job, types)

          state =
            put_state(exam, %{
              "job_id" => job.id,
              "question_id" => question_id,
              "status" => "generating"
            })

          case Repo.update_all(
                 from(e in Exam,
                   where:
                     e.id == ^exam.id and e.updated_at == ^exam.updated_at and
                       e.status == "in_progress"
                 ),
                 set: [regeneration: state, updated_at: now]
               ) do
            {1, _} -> job
            _ -> Repo.rollback(:stale)
          end
        end)

      case result do
        {:ok, job} ->
          notify(exam.id)

          case if(Keyword.get(opts, :sync, false),
                 do: CaptainHomework.Exams.Generation.run(job, lesson, pages, examples, opts),
                 else: GenerationJobs.start(job, lesson, pages, examples, opts)
               ) do
            {:ok, _} ->
              {:ok, Study.get_exam!(profile_id, exam.id)}

            {:error, _} ->
              CaptainHomework.Exams.Generation.interrupt(
                job,
                "La régénération n’a pas pu démarrer."
              )

              {:error, "La régénération n’a pas pu démarrer. La question initiale est conservée."}
          end

        _ ->
          {:error, "L’évaluation a changé. Recharge-la avant de réessayer."}
      end
    else
      _ ->
        {:error,
         "Choisis un type disponible et une question non corrigée. Vérifie que les ressources sont prêtes et que cette question n’est pas déjà en cours de régénération."}
    end
  end

  # Namespace IDs so q1 in the one-question job cannot mask q1 in the original exam.
  def surrounding(%{regeneration_source_id: nil}), do: []

  def surrounding(job) do
    case Repo.get(Exam, job.regeneration_source_id) do
      nil ->
        []

      source ->
        source.questions
        |> Enum.reject(&(&1["id"] == job.regeneration["question_id"]))
        |> Enum.map(
          &(&1
            |> Map.put("plan_id", "surrounding-" <> &1["id"])
            |> Map.put("support_id", ""))
        )
    end
  end

  def images(job, questions) do
    lesson = Repo.get!(Study.Lesson, job.lesson_id)
    lesson = Study.get_lesson!(lesson.profile_id, lesson.id)
    CaptainHomework.AI.ResourcePreflight.available_images(lesson, questions)
  end

  def guidance(%{regeneration_source_id: nil}), do: ""

  def guidance(job) do
    source = Repo.get!(Exam, job.regeneration_source_id)
    original = Enum.find(source.questions, &(&1["id"] == job.regeneration["question_id"]))
    context = Enum.map(surrounding(job), &Map.take(&1, ~w(prompt text expected_elements)))

    "\nRemplace uniquement une question jugée non pertinente. Produis une nouvelle proposition. " <>
      "Les autres questions sont conservées : ne les répète pas et ne dévoile pas leurs réponses. " <>
      "Consignes initiales de l’évaluation : #{source.instructions}\n" <>
      "Question à remplacer : #{Jason.encode!(Map.take(original, ~w(prompt text)))}\n" <>
      "Questions conservées (contexte uniquement, ne pas les retourner) : #{Jason.encode!(context)}"
  end

  def finished(%{regeneration_source_id: nil}), do: :ok

  def finished(job) do
    previous = Repo.get(Exam, job.regeneration_source_id)

    Repo.transaction(fn ->
      Repo.update_all(from(e in Exam, where: e.id == ^job.regeneration_source_id),
        set: [updated_at: DateTime.utc_now()]
      )

      source = Repo.get(Exam, job.regeneration_source_id)
      state = if source, do: state(source, job.regeneration["question_id"]), else: %{}

      if source && state["job_id"] == job.id && state["status"] == "generating" do
        valid =
          job.status == "in_progress" and length(job.questions) == 1 and
            source.status == "in_progress"

        old_id = job.regeneration["question_id"]

        attrs =
          if valid do
            [replacement] = job.questions

            replacement =
              replacement
              |> Map.put("origin_id", replacement["id"])
              |> Map.update("support_id", "", fn id ->
                if id in [nil, ""], do: "", else: "replacement-#{job.id}-#{id}"
              end)

            questions =
              Enum.map(source.questions, fn q ->
                if q["id"] == old_id,
                  do:
                    Map.put(
                      replacement,
                      "plan_id",
                      q["plan_id"] || "replacement-#{replacement["id"]}"
                    ),
                  else: q
              end)

            if replacement["definition_id"] do
              Repo.insert!(
                %Study.ExamQuestionDefinition{
                  exam_id: source.id,
                  definition_id: replacement["definition_id"],
                  snapshot: replacement["type_contract"]
                },
                on_conflict: :nothing
              )
            end

            [
              question_types: Enum.uniq(Enum.map(questions, & &1["type"])),
              questions: questions,
              answers: Map.delete(source.answers, old_id),
              corrections: Map.delete(source.corrections, old_id)
            ]
          else
            []
          end

        state =
          put_state(source, Map.put(state, "status", if(valid, do: "ready", else: "failed")))

        Repo.update_all(
          from(e in Exam, where: e.id == ^source.id and e.updated_at == ^source.updated_at),
          set: attrs ++ [regeneration: state, updated_at: DateTime.utc_now()]
        )
      end
    end)

    current = Repo.get(Exam, job.regeneration_source_id)

    if previous && current,
      do: CaptainHomework.Exams.RecordingAnswers.delete_removed(previous, current)

    notify(job.regeneration_source_id)
  end

  def notify(id),
    do: Phoenix.PubSub.broadcast(CaptainHomework.PubSub, "exam:#{id}", :exam_updated)
end

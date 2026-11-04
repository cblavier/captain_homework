defmodule CaptainHomework.Exams do
  import Ecto.Query
  alias CaptainHomework.{Repo, Study, AI, QuestionDefinitions}
  alias CaptainHomework.Study.Exam
  alias CaptainHomework.Exams.Illustrations

  def redo(profile_id, exam_id) do
    exam = Study.get_exam!(profile_id, exam_id)

    if exam.status == "completed" do
      questions = Illustrations.copy_questions(exam.questions)

      try do
        result =
          Repo.transaction(fn ->
            copy =
              Repo.insert!(%Exam{
                lesson_id: exam.lesson_id,
                format: exam.format,
                instructions: exam.instructions,
                question_types: exam.question_types,
                questions: questions
              })

            references =
              Repo.all(from r in Study.ExamQuestionDefinition, where: r.exam_id == ^exam.id)

            for reference <- references do
              Repo.insert!(%Study.ExamQuestionDefinition{
                exam_id: copy.id,
                definition_id: reference.definition_id,
                snapshot: reference.snapshot
              })
            end

            copy
          end)

        if match?({:error, _}, result),
          do: Illustrations.delete_exam_images(%{questions: questions})

        result
      rescue
        error ->
          Illustrations.delete_exam_images(%{questions: questions})
          reraise error, __STACKTRACE__
      end
    else
      {:error, :not_completed}
    end
  rescue
    File.CopyError -> {:error, :illustration_unavailable}
  end

  def retry_questions(exams, count) do
    exams
    |> Enum.filter(&(&1.status == "completed"))
    |> Enum.sort_by(& &1.submitted_at, {:desc, DateTime})
    |> Enum.flat_map(fn exam -> Enum.map(exam.questions, &{&1, exam.corrections[&1["id"]]}) end)
    |> Enum.uniq_by(fn {q, _} -> q["origin_id"] || q["id"] end)
    |> Enum.filter(fn {_, c} -> is_map(c) and is_number(c["fraction"]) and c["fraction"] < 1 end)
    |> Enum.sort_by(fn {_, c} -> c["fraction"] end)
    |> Enum.take(min(3, count))
    |> Enum.map(&elem(&1, 0))
  end

  def generate(profile_id, lesson_id, count, instructions, opts \\ [])

  def generate(profile_id, lesson_id, count, instructions, opts)
      when count in 1..30 do
    format = Keyword.get(opts, :format, "classic")
    instructions = instructions |> String.trim() |> String.slice(0, 8000)
    lesson = Study.get_lesson!(profile_id, lesson_id) |> generation_lesson(format)
    available = QuestionDefinitions.available(lesson.subject)

    requested_types =
      Keyword.get(
        opts,
        :question_types,
        available
        |> Enum.filter(
          &(QuestionDefinitions.mode_allowed?(&1, format) and
              QuestionDefinitions.generation_supported?(&1))
        )
        |> Enum.map(& &1.id)
      )

    selected =
      case QuestionDefinitions.resolve(
             lesson.subject,
             requested_types
           ) do
        {:ok, selected} -> selected
        {:error, _} -> []
      end

    selected = Enum.filter(selected, &QuestionDefinitions.mode_allowed?(&1, format))
    unsupported? = Enum.any?(selected, &(not QuestionDefinitions.generation_supported?(&1)))

    types = QuestionDefinitions.formats(selected)
    pages = Illustrations.content_pages(lesson)
    examples = Enum.filter(lesson.pages, &(&1.kind == "example"))

    previous_exams =
      Repo.all(
        from e in Exam,
          join: l in assoc(e, :lesson),
          where:
            l.profile_id == ^profile_id and l.id == ^lesson.id and
              e.status == "completed"
      )

    retries =
      if instructions != "" or format == "flashcard" or
           Illustrations.priority_exercises?(lesson) do
        []
      else
        permitted_ids = MapSet.new(selected, & &1.id)

        previous_exams
        |> Enum.filter(fn previous ->
          references = QuestionDefinitions.for_exam(previous)
          references != [] and Enum.all?(references, &MapSet.member?(permitted_ids, &1.id))
        end)
        |> retry_questions(count)
        |> Enum.filter(&(AI.question_errors(&1) == [] and &1["type"] in types))
      end

    cond do
      format not in ["classic", "flashcard"] ->
        {:error, "Choisis un format de contrôle valide."}

      unsupported? ->
        {:error,
         "Ces types sont configurables dans le catalogue, mais leur génération n’est pas encore disponible."}

      types == [] ->
        {:error, "Choisis au moins un type de question valide."}

      Illustrations.resources_pending?(lesson) ->
        {:error,
         "Attends la fin de l’analyse des ressources ou corrige les imports en erreur avant de créer le contrôle."}

      pages == [] ->
        {:error, "Ajoute au moins une page de cours ou une ressource lisible."}

      Enum.any?(pages, &(String.trim(&1.text) == "")) ->
        {:error, "Vérifie le texte de chaque page avant de créer le contrôle."}

      true ->
        with {:ok, draft} <-
               Repo.transaction(fn ->
                 exam =
                   Repo.insert!(%Exam{
                     lesson_id: lesson.id,
                     format: format,
                     instructions: instructions,
                     question_types: types,
                     questions:
                       Enum.map(
                         retries,
                         &prepare_retry/1
                       ),
                     status: "generating",
                     generation_target: count,
                     generation_examples: Enum.map(examples, & &1.id),
                     generation_started_at: DateTime.utc_now()
                   })

                 QuestionDefinitions.attach!(exam, selected)
               end) do
          dispatch_generation(draft, lesson, pages, examples, opts)
        end
    end
  end

  def generate(_, _, _, _, _), do: {:error, "Choisis entre 1 et 30 questions."}

  def generation_lesson(lesson, "flashcard"),
    do: %{
      lesson
      | pages: Enum.filter(lesson.pages, &(&1.kind == "lesson")),
        resources: [],
        exams: []
    }

  def generation_lesson(lesson, _), do: lesson

  defp prepare_retry(question) do
    question
    |> Illustrations.copy_retry()
    |> Map.drop(["verified_response_effort", "verified_answer_basis"])
    |> CaptainHomework.Exams.Generation.identify()
    |> then(&Map.put(&1, "plan_id", "retry-" <> &1["id"]))
  end

  def resume_generation(profile_id, exam_id, opts \\ []) do
    exam = Study.get_exam!(profile_id, exam_id)
    now = DateTime.utc_now()

    case Repo.update_all(
           from(e in Exam, where: e.id == ^exam.id and e.status == "generation_partial"),
           set: [status: "generating", generation_started_at: now, updated_at: now, error: nil]
         ) do
      {1, _} ->
        lesson = Study.get_lesson!(profile_id, exam.lesson_id) |> generation_lesson(exam.format)
        pages = Illustrations.content_pages(lesson)

        examples =
          Enum.filter(lesson.pages, &(&1.kind == "example"))

        exam =
          exam
          |> Ecto.Changeset.change(generation_examples: Enum.map(examples, & &1.id))
          |> Repo.update!()

        dispatch_generation(
          %{exam | status: "generating", generation_started_at: now},
          lesson,
          pages,
          examples,
          opts
        )

      _ ->
        {:error, "La génération est déjà en cours ou le contrôle est prêt."}
    end
  end

  defp dispatch_generation(exam, lesson, pages, examples, opts) do
    if Keyword.get(opts, :background, false) do
      CaptainHomework.Exams.GenerationJobs.start(exam, lesson, pages, examples, opts)
    else
      CaptainHomework.Exams.Generation.run(exam, lesson, pages, examples, opts)
    end
  end

  def submit(profile_id, exam_id, answers, opts \\ []) do
    exam = Study.get_exam!(profile_id, exam_id)
    answers = Study.sanitize_answers(exam, answers)
    now = DateTime.utc_now()

    case Repo.update_all(
           from(e in Exam,
             where:
               e.id == ^exam.id and e.status == "in_progress" and e.format == "classic" and
                 e.updated_at == ^exam.updated_at
           ),
           set: [
             status: "grading",
             answers: answers,
             grading_started_at: now,
             updated_at: now,
             error: nil
           ]
         ) do
      {1, _} ->
        work = fn ->
          grade(%{exam | answers: answers, status: "grading", grading_started_at: now})
        end

        if Keyword.get(opts, :sync, false),
          do: work.(),
          else: Task.Supervisor.start_child(CaptainHomework.Tasks, work)

        {:ok, Study.get_exam!(profile_id, exam_id)}

      _ ->
        {:error, :already_submitted}
    end
  end

  def grade(exam) do
    result =
      try do
        with {:ok, grades} <- AI.grade(exam),
             {:ok, corrections, score} <- validate_grades(exam, grades) do
          {:ok, corrections, score, if(is_map(grades), do: grades["appreciation"])}
        end
      rescue
        _ -> {:error, "La correction a été interrompue. Tu peux réessayer."}
      end

    attrs =
      case result do
        {:ok, corrections, score, appreciation} ->
          [
            status: "completed",
            corrections: corrections,
            score: score,
            appreciation: appreciation,
            submitted_at: DateTime.utc_now(),
            error: nil
          ]

        {:error, reason} ->
          [status: "in_progress", error: AI.message(reason)]
      end

    Repo.update_all(
      from(e in Exam,
        where:
          e.id == ^exam.id and e.status == "grading" and
            e.grading_started_at == ^exam.grading_started_at
      ),
      set: attrs ++ [updated_at: DateTime.utc_now()]
    )

    Phoenix.PubSub.broadcast(CaptainHomework.PubSub, "exam:#{exam.id}", :exam_updated)

    case result do
      {:ok, corrections, score, _} -> {:ok, corrections, score}
      error -> error
    end
  end

  def validate_grades(exam, %{"grades" => grades, "appreciation" => appreciation})
      when is_binary(appreciation) and byte_size(appreciation) > 0 do
    validate_grades(exam, grades)
  end

  def validate_grades(exam, grades) when is_list(grades) do
    by_id = Map.new(grades, &{&1["id"], &1})

    valid =
      length(grades) == length(exam.questions) and map_size(by_id) == length(exam.questions) and
        Enum.all?(exam.questions, fn q ->
          c = by_id[q["id"]]
          is_map(c) and c["fraction"] in [0, 0.25, 0.5, 0.75, 1] and is_binary(c["feedback"])
        end)

    if valid do
      corrections =
        Map.new(exam.questions, fn q ->
          c = by_id[q["id"]]

          fraction =
            cond do
              blank?(exam.answers[q["id"]]) -> 0
              q["type"] == "mcq" -> if(exam.answers[q["id"]] == q["answer"], do: 1, else: 0)
              true -> c["fraction"]
            end

          {q["id"],
           %{
             "fraction" => fraction,
             "points" => q["points"] * fraction,
             "feedback" =>
               if(q["type"] == "mcq",
                 do:
                   if(fraction == 1,
                     do: "Bonne réponse.",
                     else: "La bonne réponse est : #{q["answer"]}"
                   ),
                 else: c["feedback"]
               ),
             "expected" => q["answer"],
             "language_errors" =>
               if(q["type"] in ["mcq", "photo"],
                 do: [],
                 else:
                   CaptainHomework.Exams.Language.validate(
                     exam.answers[q["id"]],
                     Map.get(c, "language_errors", [])
                   )
               )
           }}
        end)

      total = Enum.sum(Enum.map(exam.questions, & &1["points"]))
      earned = Enum.sum(Enum.map(corrections, fn {_, c} -> c["points"] end))
      {:ok, corrections, round_score(20 * earned / total)}
    else
      {:error, "La correction reçue est incomplète. Tu peux réessayer sans perdre tes réponses."}
    end
  end

  def validate_grades(_, _), do: {:error, "La correction reçue est invalide."}
  def round_score(score) when is_number(score), do: round(score * 4) / 4
  def round_score(score), do: score

  def raw_score(exam) do
    earned = Enum.sum(Enum.map(exam.corrections, fn {_, c} -> c["points"] || 0 end))
    total = Enum.sum(Enum.map(exam.questions, & &1["points"]))
    {earned, total}
  end

  def blank?(v) when is_map(v), do: Enum.all?(v, fn {_, value} -> blank?(value) end)
  def blank?(v) when is_binary(v), do: String.trim(v) == ""
  def blank?(_), do: true

  def recover_stale(%{status: "generating", generation_started_at: started} = exam)
      when not is_nil(started) do
    if DateTime.diff(DateTime.utc_now(), started) > 5 and
         not CaptainHomework.Exams.GenerationJobs.running?(exam) do
      CaptainHomework.Exams.Generation.interrupt(
        exam,
        "La génération a été interrompue. Les questions prêtes sont conservées ; reprends les questions manquantes."
      )
    end

    exam
  end

  def recover_stale(exam) do
    if exam.status == "grading" and
         DateTime.diff(DateTime.utc_now(), exam.grading_started_at) > 300 do
      Repo.update_all(from(e in Exam, where: e.id == ^exam.id and e.status == "grading"),
        set: [
          status: "in_progress",
          error: "La correction a été interrompue. Tu peux rendre ta copie à nouveau."
        ]
      )
    end

    exam
  end
end

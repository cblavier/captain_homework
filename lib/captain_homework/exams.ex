defmodule CaptainHomework.Exams do
  import Ecto.Query
  alias CaptainHomework.{Repo, Study, AI}
  alias CaptainHomework.Study.Exam
  alias CaptainHomework.Exams.Illustrations

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

  def generate(profile_id, lesson_id, count, instructions, example_ids, opts \\ [])

  def generate(profile_id, lesson_id, count, instructions, example_ids, opts)
      when count in 1..30 do
    lesson = Study.get_lesson!(profile_id, lesson_id)
    pages = Illustrations.content_pages(lesson)
    examples = Enum.filter(lesson.pages, &(&1.kind == "example" and &1.id in example_ids))

    previous_exams =
      Repo.all(
        from e in Exam,
          join: l in assoc(e, :lesson),
          where:
            l.profile_id == ^profile_id and l.subject == ^lesson.subject and
              e.status == "completed"
      )

    retries =
      if Illustrations.priority_exercises?(lesson) do
        []
      else
        retry_questions(previous_exams, count) |> Enum.filter(&(AI.question_errors(&1) == []))
      end

    additional = instructions |> String.trim() |> String.slice(0, 8000)
    instructions = Study.default_instructions()

    instructions =
      if additional == "",
        do: instructions,
        else:
          instructions <> "\n\nInstructions supplémentaires pour ce contrôle :\n" <> additional

    cond do
      Illustrations.resources_pending?(lesson) ->
        {:error,
         "Attends la fin de l’analyse des ressources ou corrige les imports en erreur avant de créer le contrôle."}

      pages == [] ->
        {:error, "Ajoute au moins une page de cours ou une ressource lisible."}

      Enum.any?(pages, &(String.trim(&1.text) == "")) ->
        {:error, "Vérifie le texte de chaque page avant de créer le contrôle."}

      true ->
        with {:ok, draft} <-
               Repo.insert(%Exam{
                 lesson_id: lesson.id,
                 instructions: instructions,
                 questions:
                   Enum.map(
                     retries,
                     &(Illustrations.copy_retry(&1)
                       |> CaptainHomework.Exams.Generation.identify())
                   ),
                 status: "generating",
                 generation_target: count,
                 generation_examples: Enum.map(examples, & &1.id),
                 generation_started_at: DateTime.utc_now()
               }) do
          CaptainHomework.Exams.Generation.run(draft, lesson, pages, examples, opts)
        end
    end
  end

  def generate(_, _, _, _, _, _), do: {:error, "Choisis entre 1 et 30 questions."}

  def resume_generation(profile_id, exam_id, opts \\ []) do
    exam = Study.get_exam!(profile_id, exam_id)
    now = DateTime.utc_now()

    case Repo.update_all(
           from(e in Exam, where: e.id == ^exam.id and e.status == "generation_partial"),
           set: [status: "generating", generation_started_at: now, updated_at: now]
         ) do
      {1, _} ->
        lesson = Study.get_lesson!(profile_id, exam.lesson_id)
        pages = Illustrations.content_pages(lesson)

        examples =
          Enum.filter(lesson.pages, &(&1.kind == "example" and &1.id in exam.generation_examples))

        CaptainHomework.Exams.Generation.run(
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

  def submit(profile_id, exam_id, answers, opts \\ []) do
    exam = Study.get_exam!(profile_id, exam_id)
    answers = Study.sanitize_answers(exam, answers)
    now = DateTime.utc_now()

    case Repo.update_all(from(e in Exam, where: e.id == ^exam.id and e.status == "in_progress"),
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
          {:ok, corrections, score}
        end
      rescue
        _ -> {:error, "La correction a été interrompue. Tu peux réessayer."}
      end

    attrs =
      case result do
        {:ok, corrections, score} ->
          [
            status: "completed",
            corrections: corrections,
            score: score,
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
    result
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
             "expected" => q["answer"]
           }}
        end)

      total = Enum.sum(Enum.map(exam.questions, & &1["points"]))
      earned = Enum.sum(Enum.map(corrections, fn {_, c} -> c["points"] end))
      {:ok, corrections, Float.round(20 * earned / total, 2)}
    else
      {:error, "La correction reçue est incomplète. Tu peux réessayer sans perdre tes réponses."}
    end
  end

  def validate_grades(_, _), do: {:error, "La correction reçue est invalide."}
  def blank?(v) when is_map(v), do: Enum.all?(v, fn {_, value} -> blank?(value) end)
  def blank?(v) when is_binary(v), do: String.trim(v) == ""
  def blank?(_), do: true

  def recover_stale(%{status: "generating", generation_started_at: started} = exam)
      when not is_nil(started) do
    if DateTime.diff(DateTime.utc_now(), started) > 900 do
      Repo.update_all(
        from(e in Exam,
          where:
            e.id == ^exam.id and e.status == "generating" and e.generation_started_at == ^started
        ),
        set: [
          status: "generation_partial",
          error: "La génération a été interrompue. Les questions prêtes sont conservées."
        ]
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

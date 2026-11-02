defmodule CaptainHomework.Exams.Flashcards do
  import Ecto.Query
  alias CaptainHomework.{AI, Exams, Repo, Study}
  alias CaptainHomework.Study.Exam

  def current(exam), do: Enum.at(exam.questions, exam.card_index)

  def submit(profile_id, exam_id, question_id, answer, opts \\ []) do
    exam = Study.get_exam!(profile_id, exam_id)
    question = current(exam)

    if exam.format == "flashcard" and exam.status == "in_progress" and not is_nil(question) and
         question["id"] == question_id and not Map.has_key?(exam.corrections, question_id) do
      answers = Study.sanitize_answers(exam, Map.put(exam.answers, question_id, answer))
      now = DateTime.utc_now()

      case Repo.update_all(
             from(e in Exam,
               where:
                 e.id == ^exam.id and e.status == "in_progress" and
                   e.updated_at == ^exam.updated_at
             ),
             set: [
               answers: answers,
               status: "grading",
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

          notify(exam)
          {:ok, Study.get_exam!(profile_id, exam_id)}

        _ ->
          {:error, :stale_card}
      end
    else
      {:error, :stale_card}
    end
  end

  defp grade(exam) do
    single = %{exam | questions: [current(exam)]}

    result =
      try do
        with {:ok, grades} <- AI.grade(single),
             {:ok, corrections, _} <- Exams.validate_grades(single, grades) do
          {:ok, Map.merge(exam.corrections, corrections)}
        end
      rescue
        _ -> {:error, "La correction a été interrompue. Réessaie cette carte."}
      end

    attrs =
      case result do
        {:ok, corrections} -> [corrections: corrections, error: nil]
        {:error, reason} -> [error: AI.message(reason)]
      end

    Repo.update_all(
      from(e in Exam,
        where:
          e.id == ^exam.id and e.status == "grading" and
            e.grading_started_at == ^exam.grading_started_at
      ),
      set: attrs ++ [status: "in_progress", updated_at: DateTime.utc_now()]
    )

    notify(exam)
  end

  def advance(profile_id, exam_id, question_id) do
    exam = Study.get_exam!(profile_id, exam_id)
    question = current(exam)

    if exam.format == "flashcard" and exam.status == "in_progress" and not is_nil(question) and
         question["id"] == question_id and Map.has_key?(exam.corrections, question_id) do
      attrs =
        if exam.card_index + 1 == length(exam.questions) do
          {earned, total} = Exams.raw_score(exam)
          score = Exams.round_score(20 * earned / total)

          [
            status: "completed",
            score: score,
            submitted_at: DateTime.utc_now(),
            appreciation: appreciation(exam)
          ]
        else
          [card_index: exam.card_index + 1]
        end

      case Repo.update_all(
             from(e in Exam,
               where:
                 e.id == ^exam.id and e.status == "in_progress" and
                   e.updated_at == ^exam.updated_at
             ),
             set: attrs ++ [updated_at: DateTime.utc_now()]
           ) do
        {1, _} ->
          notify(exam)
          {:ok, Study.get_exam!(profile_id, exam_id)}

        _ ->
          {:error, :stale_card}
      end
    else
      {:error, :stale_card}
    end
  end

  defp appreciation(exam) do
    if Enum.all?(exam.corrections, fn {_, c} -> c["fraction"] == 1 end),
      do: "Bravo, tu maîtrises toutes les notions de cette série !",
      else:
        "Révision terminée ! Relis les corrections des cartes à revoir pour consolider tes connaissances."
  end

  def validate_candidates(questions, pages) do
    source_ids = MapSet.new(pages, & &1.id)

    {valid, invalid} =
      Enum.split_with(questions, fn q ->
        ids = q["source_page_ids"]

        is_list(ids) and ids != [] and Enum.all?(ids, &MapSet.member?(source_ids, &1)) and
          q["response_effort"] == "direct" and q["answer_basis"] == "knowledge" and
          q["support_id"] in [nil, ""] and Map.get(q, "image_ids", []) == []
      end)

    {Enum.map(valid, &Map.put(&1, "points", 1)),
     if(invalid == [],
       do: [],
       else: [
         "Chaque flashcard doit être rapide, autonome et fondée uniquement sur les pages de cours."
       ]
     )}
  end

  defp notify(exam) do
    Phoenix.PubSub.broadcast(CaptainHomework.PubSub, "exam:#{exam.id}", :exam_updated)
    Phoenix.PubSub.broadcast(CaptainHomework.PubSub, "lesson:#{exam.lesson_id}", :lesson_updated)
  end
end

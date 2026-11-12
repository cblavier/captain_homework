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
                   e.updated_at == ^exam.updated_at and
                   fragment(
                     "COALESCE(json_extract(?, '$.status'), '') NOT IN ('generating', 'failed')",
                     e.regeneration
                   )
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

  def browse(profile_id, exam_id, direction) when direction in ["previous", "next"] do
    exam = Study.get_exam!(profile_id, exam_id)
    index = exam.card_index + if(direction == "previous", do: -1, else: 1)

    if exam.format == "flashcard" and exam.status == "in_progress" and
         index >= 0 and index < length(exam.questions) do
      case Repo.update_all(
             from(e in Exam,
               where:
                 e.id == ^exam.id and e.status == "in_progress" and
                   e.updated_at == ^exam.updated_at and
                   fragment(
                     "COALESCE(json_extract(?, '$.status'), '') NOT IN ('generating', 'failed')",
                     e.regeneration
                   )
             ),
             set: [card_index: index, updated_at: DateTime.utc_now()]
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

  def browse(_, _, _), do: {:error, :invalid_direction}

  def finishable?(exam) do
    exam.card_index + 1 == length(exam.questions) and
      Enum.all?(exam.questions, &Map.has_key?(exam.corrections, &1["id"]))
  end

  def advance(profile_id, exam_id, question_id) do
    exam = Study.get_exam!(profile_id, exam_id)
    question = current(exam)

    if exam.format == "flashcard" and exam.status == "in_progress" and not is_nil(question) and
         question["id"] == question_id and Map.has_key?(exam.corrections, question_id) do
      attrs =
        if finishable?(exam) do
          {earned, total} = Exams.raw_score(exam)
          score = Exams.round_score(20 * earned / total)

          [
            status: "completed",
            score: score,
            submitted_at: DateTime.utc_now(),
            appreciation: appreciation(exam)
          ]
        else
          index =
            if exam.card_index + 1 < length(exam.questions),
              do: exam.card_index + 1,
              else:
                Enum.find_index(exam.questions, &(not Map.has_key?(exam.corrections, &1["id"])))

          [card_index: index]
        end

      case Repo.update_all(
             from(e in Exam,
               where:
                 e.id == ^exam.id and e.status == "in_progress" and
                   e.updated_at == ^exam.updated_at and
                   fragment(
                     "COALESCE(json_extract(?, '$.status'), '') NOT IN ('generating', 'failed')",
                     e.regeneration
                   )
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
          q["response_effort"] == "direct" and
          valid_answer_basis?(q) and
          q["support_id"] in [nil, ""] and Map.get(q, "image_ids", []) == [] and
          not answer_repeated_in_text?(q)
      end)

    {Enum.map(valid, &Map.put(&1, "points", 1)),
     if(invalid == [],
       do: [],
       else: [
         "Chaque flashcard doit être rapide, autonome et fondée uniquement sur les sources du chapitre retenues pour la révision. Le champ text ne doit pas répéter la réponse attendue."
       ]
     )}
  end

  defp valid_answer_basis?(%{"type" => type, "answer_basis" => basis})
       when type in ["listening", "pronunciation"],
       do: basis == "document"

  defp valid_answer_basis?(%{"answer_basis" => "document"} = question),
    do: CaptainHomework.Exams.VisibleSupport.present?(question)

  defp valid_answer_basis?(question), do: question["answer_basis"] == "knowledge"

  def answer_repeated_in_text?(%{"type" => "pronunciation"}), do: false

  def answer_repeated_in_text?(question) do
    answer = normalize_answer(question["answer"])
    answer != "" and normalize_answer(question["text"]) == answer
  end

  defp normalize_answer(value) when is_binary(value) do
    value
    |> String.normalize(:nfc)
    |> String.downcase()
    |> String.replace(["’", "‘"], "'")
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> String.replace(~r/[.!?…]+$/u, "")
    |> String.trim()
  end

  defp normalize_answer(_), do: ""

  defp notify(exam) do
    Phoenix.PubSub.broadcast(CaptainHomework.PubSub, "exam:#{exam.id}", :exam_updated)
    Phoenix.PubSub.broadcast(CaptainHomework.PubSub, "lesson:#{exam.lesson_id}", :lesson_updated)
  end
end

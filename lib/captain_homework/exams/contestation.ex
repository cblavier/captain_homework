defmodule CaptainHomework.Exams.Contestation do
  @moduledoc "Rechecks one correction and atomically updates its exam."
  import Ecto.Query
  alias CaptainHomework.{AI, Exams, Repo, Study}
  alias CaptainHomework.Study.Exam

  def submit(profile_id, exam_id, question_id, explanation) when is_binary(explanation) do
    exam = Study.get_exam!(profile_id, exam_id)
    question = Enum.find(exam.questions, &(&1["id"] == question_id))

    if exam.status == "completed" and is_map(question) and
         is_map(exam.corrections[question_id]) and String.length(explanation) <= 4000 do
      reconsider(exam, question, String.trim(explanation))
    else
      {:error, "Cet exercice ne peut pas être contesté."}
    end
  end

  defp reconsider(exam, question, explanation) do
    with {:ok, result} <- AI.reconsider(exam, question["id"], explanation),
         {:ok, updated_question, correction, appreciation} <-
           validate(exam, question, result) do
      questions =
        Enum.map(exam.questions, fn q ->
          if q["id"] == question["id"], do: updated_question, else: q
        end)

      previous = exam.corrections[question["id"]]

      history = %{
        "explanation" => explanation,
        "previous" => Map.delete(previous, "contestations"),
        "reviewed_at" => DateTime.to_iso8601(DateTime.utc_now())
      }

      correction =
        Map.put(correction, "contestations", Map.get(previous, "contestations", []) ++ [history])

      corrections = Map.put(exam.corrections, question["id"], correction)
      total = Enum.sum(Enum.map(questions, & &1["points"]))
      earned = Enum.sum(Enum.map(corrections, fn {_, c} -> c["points"] end))
      score = Exams.round_score(20 * earned / total)

      case Repo.update_all(
             from(e in Exam,
               where:
                 e.id == ^exam.id and e.status == "completed" and
                   e.updated_at == ^exam.updated_at
             ),
             set: [
               questions: questions,
               corrections: corrections,
               score: score,
               appreciation: appreciation,
               updated_at: DateTime.utc_now()
             ]
           ) do
        {1, _} ->
          Phoenix.PubSub.broadcast(CaptainHomework.PubSub, "exam:#{exam.id}", :exam_updated)
          {:ok, Repo.get!(Exam, exam.id)}

        _ ->
          {:error, "Le contrôle a changé pendant la vérification. Recharge-le et réessaie."}
      end
    end
  rescue
    _ -> {:error, "La vérification a échoué. La correction précédente est conservée."}
  end

  defp validate(exam, question, %{"grades" => [grade], "appreciation" => appreciation})
       when is_binary(appreciation) and byte_size(appreciation) > 0 do
    expected = grade["expected"]

    if grade["id"] == question["id"] and is_binary(expected) and
         String.trim(expected) != "" and
         (question["type"] != "mcq" or expected in question["options"]) do
      updated_question =
        Map.merge(question, %{"answer" => expected, "expected_elements" => [expected]})

      with {:ok, corrections, _} <-
             Exams.validate_grades(%{exam | questions: [updated_question]}, [grade]) do
        {:ok, updated_question, corrections[question["id"]], appreciation}
      end
    else
      {:error, "Le résultat de la vérification est invalide. La correction est conservée."}
    end
  end

  defp validate(_, _, _), do: {:error, "La vérification reçue est incomplète."}
end

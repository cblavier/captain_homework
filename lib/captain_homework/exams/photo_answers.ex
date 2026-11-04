defmodule CaptainHomework.Exams.PhotoAnswers do
  import Ecto.Query
  alias CaptainHomework.{Repo, Study, Uploads}
  alias CaptainHomework.Study.Exam

  def put(profile_id, exam_id, question_id, path, filename) do
    exam = Study.get_exam!(profile_id, exam_id)

    with :ok <- editable(exam, question_id),
         {:ok, asset} <- Uploads.store(path, filename) do
      asset =
        asset
        |> Map.take([:filename, :storage_key, :content_type])
        |> Map.put(:id, Ecto.UUID.generate())
        |> Jason.encode!()
        |> Jason.decode!()

      case persist(exam, question_id, asset) do
        {:ok, updated} ->
          remove_file(exam.answers[question_id])
          {:ok, updated}

        error ->
          remove_file(asset)
          error
      end
    end
  end

  def remove(profile_id, exam_id, question_id) do
    exam = Study.get_exam!(profile_id, exam_id)

    with :ok <- editable(exam, question_id),
         {:ok, updated} <- persist(exam, question_id, "") do
      remove_file(exam.answers[question_id])
      {:ok, updated}
    end
  end

  def assets(exam) do
    for q <- exam.questions,
        q["type"] == "photo",
        asset = exam.answers[q["id"]],
        is_map(asset),
        is_binary(asset["storage_key"]),
        do: asset
  end

  def delete_files(exam), do: Enum.each(assets(exam), &remove_file/1)

  defp editable(exam, id) do
    if exam.format == "classic" and exam.status == "in_progress" and
         Enum.any?(exam.questions, &(&1["id"] == id and &1["type"] == "photo")),
       do: :ok,
       else: {:error, "Cette réponse ne peut plus être modifiée."}
  end

  defp persist(exam, id, asset) do
    answers = Map.put(exam.answers, id, asset)
    now = DateTime.utc_now()

    case Repo.update_all(
           from(e in Exam,
             where:
               e.id == ^exam.id and e.status == "in_progress" and e.updated_at == ^exam.updated_at
           ),
           set: [answers: answers, updated_at: now]
         ) do
      {1, _} -> {:ok, %{exam | answers: answers, updated_at: now}}
      _ -> {:error, "La copie a changé. Réessaie après avoir rechargé la page."}
    end
  end

  defp remove_file(%{"storage_key" => key}), do: File.rm(Uploads.path(key))
  defp remove_file(_), do: :ok
end

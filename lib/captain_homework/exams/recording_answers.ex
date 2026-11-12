defmodule CaptainHomework.Exams.RecordingAnswers do
  import Ecto.Query
  alias CaptainHomework.{Repo, Study, Uploads}
  alias CaptainHomework.Study.Exam
  alias CaptainHomework.Resources.MediaCommand

  def put(profile_id, exam_id, question_id, path) do
    {exam, version} = snapshot(profile_id, exam_id)

    with :ok <- editable(exam, question_id),
         {:ok, asset} <- store(path) do
      case persist(exam, version, question_id, asset) do
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
    {exam, version} = snapshot(profile_id, exam_id)

    with :ok <- editable(exam, question_id),
         {:ok, updated} <- persist(exam, version, question_id, "") do
      remove_file(exam.answers[question_id])
      {:ok, updated}
    end
  end

  def assets(exam) do
    for q <- exam.questions,
        q["type"] == "pronunciation",
        asset = exam.answers[q["id"]],
        is_map(asset),
        is_binary(asset["storage_key"]),
        do: asset
  end

  def delete_files(exam), do: Enum.each(assets(exam), &remove_file/1)

  def delete_removed(previous, current) do
    kept = MapSet.new(assets(current), & &1["storage_key"])

    previous
    |> assets()
    |> Enum.reject(&MapSet.member?(kept, &1["storage_key"]))
    |> Enum.each(&remove_file/1)
  end

  defp editable(exam, id) do
    current = CaptainHomework.Exams.Flashcards.current(exam)
    state = CaptainHomework.Exams.QuestionRegeneration.states(exam)[id] || %{}

    if exam.status == "in_progress" and state["status"] not in ~w(generating failed) and
         not Map.has_key?(exam.corrections, id) and
         Enum.any?(exam.questions, &(&1["id"] == id and &1["type"] == "pronunciation")) and
         (exam.format == "classic" or (current && current["id"] == id)),
       do: :ok,
       else: {:error, "Cet enregistrement ne peut plus être modifié."}
  end

  defp store(path) do
    key = Ecto.UUID.generate() <> ".wav"
    File.mkdir_p!(Uploads.directory())
    output = Uploads.path(key)

    result =
      with {:ok, %{size: size}} when size in 1..5_000_000 <- File.stat(path),
           {:ok, _} <-
             MediaCommand.run(
               "ffmpeg",
               [
                 "-nostdin",
                 "-v",
                 "error",
                 "-y",
                 "-format_whitelist",
                 "mp3,mov,matroska,webm,ogg,wav,aac",
                 "-protocol_whitelist",
                 "file,pipe",
                 "-i",
                 path,
                 "-map",
                 "0:a:0",
                 "-vn",
                 "-map_metadata",
                 "-1",
                 "-t",
                 "61",
                 "-ac",
                 "1",
                 "-ar",
                 "16000",
                 "-c:a",
                 "pcm_s16le",
                 output
               ],
               30_000
             ),
           {:ok, info} <-
             MediaCommand.run(
               "ffprobe",
               [
                 "-v",
                 "error",
                 "-show_entries",
                 "format=duration",
                 "-of",
                 "default=noprint_wrappers=1:nokey=1",
                 output
               ],
               10_000
             ),
           {duration, _} when duration >= 0.2 and duration <= 60.5 <-
             Float.parse(String.trim(info)) do
        {:ok,
         %{
           "id" => Ecto.UUID.generate(),
           "storage_key" => key,
           "content_type" => "audio/wav",
           "filename" => "prononciation.wav"
         }}
      else
        _ -> {:error, "Enregistre ta voix pendant 60 secondes maximum (5 Mo), puis réessaie."}
      end

    if match?({:error, _}, result), do: File.rm(output)
    result
  end

  defp snapshot(profile_id, exam_id) do
    {:ok, snapshot} =
      Repo.transaction(fn ->
        exam = Study.get_exam!(profile_id, exam_id)

        version =
          Repo.one!(
            from e in Exam,
              where: e.id == ^exam.id,
              select: fragment("CAST(? AS TEXT)", e.updated_at)
          )

        {exam, version}
      end)

    snapshot
  end

  defp persist(exam, version, id, asset) do
    answers = Map.put(exam.answers, id, asset)
    now = DateTime.utc_now()

    case Repo.update_all(
           from(e in Exam,
             where:
               e.id == ^exam.id and e.status == "in_progress" and
                 fragment("CAST(? AS TEXT)", e.updated_at) == ^version
           ),
           set: [answers: answers, updated_at: now]
         ) do
      {1, _} -> {:ok, %{exam | answers: answers, updated_at: now}}
      _ -> {:error, "La copie a changé. Recharge la page avant de réenregistrer."}
    end
  end

  defp remove_file(%{"storage_key" => key}), do: File.rm(Uploads.path(key))
  defp remove_file(_), do: :ok
end

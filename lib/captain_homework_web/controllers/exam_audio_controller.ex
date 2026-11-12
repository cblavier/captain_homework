defmodule CaptainHomeworkWeb.ExamAudioController do
  use CaptainHomeworkWeb, :controller
  alias CaptainHomework.{Study, Uploads}

  def show(conn, %{"exam_id" => exam_id, "id" => id} = params) do
    profile =
      if params["child"],
        do: CaptainHomeworkWeb.ProfilePath.find(params["child"]),
        else: conn.assigns.profile

    if profile do
      exam =
        try do
          Study.get_exam!(profile.id, exam_id)
        rescue
          Ecto.NoResultsError ->
            if CaptainHomework.Accounts.parent?(conn.assigns.account) do
              CaptainHomework.ExamShares.get_owner_correction!(profile.id, exam_id)
            else
              raise Ecto.NoResultsError, queryable: CaptainHomework.Study.Exam
            end
        end

      asset =
        Enum.find_value(exam.questions, fn q ->
          if q["type"] == "listening" and is_map(q["audio"]) and q["audio"]["id"] == id,
            do: q["audio"]
        end)

      asset =
        asset || Enum.find(CaptainHomework.Exams.RecordingAnswers.assets(exam), &(&1["id"] == id))

      if asset && File.regular?(Uploads.path(asset["storage_key"])) do
        conn
        |> put_resp_content_type(asset["content_type"] || "audio/mpeg")
        |> put_resp_header("cache-control", "private, no-store")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> send_file(200, Uploads.path(asset["storage_key"]))
      else
        send_resp(conn, 404, "Extrait audio introuvable")
      end
    else
      send_resp(conn, 404, "Extrait audio introuvable")
    end
  end
end

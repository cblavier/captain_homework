defmodule CaptainHomeworkWeb.ExamAudioController do
  use CaptainHomeworkWeb, :controller
  alias CaptainHomework.{Study, Uploads}

  def show(conn, %{"exam_id" => exam_id, "id" => id} = params) do
    profile =
      if params["child"],
        do: CaptainHomeworkWeb.ProfilePath.find(params["child"]),
        else: conn.assigns.profile

    if profile do
      exam = Study.get_exam!(profile.id, exam_id)

      asset =
        Enum.find_value(exam.questions, fn q ->
          if q["type"] == "listening" and is_map(q["audio"]) and q["audio"]["id"] == id,
            do: q["audio"]
        end)

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

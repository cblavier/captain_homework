defmodule CaptainHomeworkWeb.ExamImageController do
  use CaptainHomeworkWeb, :controller
  alias CaptainHomework.{Study, Uploads}

  def show(conn, %{"exam_id" => exam_id, "id" => id} = params) do
    profile =
      if params["child"],
        do: CaptainHomeworkWeb.ProfilePath.find(params["child"]),
        else: Study.get_profile(get_session(conn, :profile_id)) || List.first(Study.profiles())

    if profile do
      exam = Study.get_exam!(profile.id, exam_id)

      asset =
        exam.questions
        |> Enum.flat_map(&Map.get(&1, "images", []))
        |> Kernel.++(CaptainHomework.Exams.PhotoAnswers.assets(exam))
        |> Enum.find(&(&1["id"] == id))

      if asset && File.regular?(Uploads.path(asset["storage_key"])) do
        conn
        |> put_resp_content_type(asset["content_type"])
        |> put_resp_header("cache-control", "private, no-store")
        |> put_resp_header("x-content-type-options", "nosniff")
        |> send_file(200, Uploads.path(asset["storage_key"]))
      else
        send_resp(conn, 404, "Illustration introuvable")
      end
    else
      send_resp(conn, 404, "Illustration introuvable")
    end
  end
end

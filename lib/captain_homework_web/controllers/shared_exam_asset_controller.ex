defmodule CaptainHomeworkWeb.SharedExamAssetController do
  use CaptainHomeworkWeb, :controller
  alias CaptainHomework.{ExamShares, Repo, Uploads}
  import Ecto.Query
  alias CaptainHomework.Study.Exam

  def image(conn, params), do: serve(conn, params, :image)
  def audio(conn, params), do: serve(conn, params, :audio)

  defp serve(conn, %{"token" => token, "id" => id}, kind) do
    with {:ok, share} <- ExamShares.fetch(token),
         exam <- visible_exam(share, get_session(conn, :shared_visitor)),
         asset when is_map(asset) <- find_asset(exam, id, kind),
         true <- File.regular?(Uploads.path(asset["storage_key"])) do
      conn
      |> put_resp_content_type(asset["content_type"])
      |> put_resp_header("x-content-type-options", "nosniff")
      |> send_file(200, Uploads.path(asset["storage_key"]))
    else
      _ -> send_resp(conn, 404, "Fichier indisponible")
    end
  end

  defp visible_exam(%{mode: "correction", exam: exam}, _), do: exam

  defp visible_exam(share, visitor) do
    hash = :crypto.hash(:sha256, visitor)

    Repo.one(
      from e in Exam, where: e.exam_share_id == ^share.id and e.shared_visitor_hash == ^hash
    ) || %{share.exam | answers: %{}}
  end

  defp find_asset(exam, id, :image) do
    (Enum.flat_map(exam.questions, &Map.get(&1, "images", [])) ++
       CaptainHomework.Exams.PhotoAnswers.assets(exam))
    |> Enum.find(&(&1["id"] == id))
  end

  defp find_asset(exam, id, :audio) do
    Enum.find_value(exam.questions, fn q ->
      if q["type"] == "listening" and is_map(q["audio"]) and q["audio"]["id"] == id,
        do: q["audio"]
    end)
  end
end

defmodule CaptainHomework.ExamShares do
  import Ecto.Query
  alias CaptainHomework.{Repo, Study}
  alias CaptainHomework.Study.{Exam, ExamShare}

  @lifetime_days 7
  def lifetime_days, do: @lifetime_days

  def token, do: :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  defp digest(token), do: :crypto.hash(:sha256, token)

  def create(profile_id, exam_id, mode) when mode in ["correction", "fill"] do
    exam = Study.get_exam!(profile_id, exam_id)

    if exam.questions != [] and
         (exam.status == "completed" or
            (mode == "fill" and exam.status in ["in_progress", "grading"])) do
      token = token()

      share = %ExamShare{
        exam_id: exam.id,
        token_hash: digest(token),
        mode: mode,
        expires_at: if(mode == "fill", do: DateTime.add(DateTime.utc_now(), @lifetime_days, :day))
      }

      case Repo.insert(share) do
        {:ok, share} -> {:ok, share, token}
        error -> error
      end
    else
      {:error, :unavailable}
    end
  end

  def create(_, _, _), do: {:error, :unavailable}

  def fetch(token) when is_binary(token) and byte_size(token) == 43 do
    hash = digest(token)
    now = DateTime.utc_now()

    case Repo.one(
           from s in ExamShare,
             where: s.token_hash == ^hash and (is_nil(s.expires_at) or s.expires_at > ^now),
             preload: [exam: :lesson]
         ) do
      nil -> {:error, :unavailable}
      share -> {:ok, share}
    end
  end

  def fetch(_), do: {:error, :unavailable}

  # The visitor secret lives in the signed, HTTP-only session, never in the shared URL.
  # Each browser gets its own copy; the original and other visitors remain inaccessible.
  def open(token, visitor) when is_binary(visitor) do
    with {:ok, share} <- fetch(token) do
      case share.mode do
        "correction" -> {:ok, share, share.exam}
        "fill" -> {:ok, share, find_or_create_attempt(share, visitor)}
      end
    end
  end

  def open(_, _), do: {:error, :unavailable}

  def attempts_for_exam(exam_id) do
    Repo.all(
      from e in Exam,
        join: s in ExamShare,
        on: s.id == e.exam_share_id,
        where: s.exam_id == ^exam_id
    )
  end

  def get_exam!({:shared, token, visitor}, id) do
    with true <- Study.valid_id?(id),
         {:ok, share} <- fetch(token),
         %Exam{} = exam <- authorized_exam(share, visitor, id) do
      exam
    else
      _ -> raise Ecto.NoResultsError, queryable: Exam
    end
  end

  defp authorized_exam(%{mode: "correction", exam_id: id, exam: exam}, _, id), do: exam

  defp authorized_exam(%{mode: "fill", id: share_id}, visitor, id) when is_binary(visitor) do
    hash = digest(visitor)

    Repo.one(
      from e in Exam,
        where: e.id == ^id and e.exam_share_id == ^share_id and e.shared_visitor_hash == ^hash,
        preload: [:lesson]
    )
  end

  defp authorized_exam(_, _, _), do: nil

  defp find_or_create_attempt(share, visitor) do
    hash = digest(visitor)
    query = from e in Exam, where: e.exam_share_id == ^share.id and e.shared_visitor_hash == ^hash

    if is_nil(Repo.one(query)) do
      Repo.insert!(
        %Exam{
          lesson_id: share.exam.lesson_id,
          exam_share_id: share.id,
          shared_visitor_hash: hash,
          instructions: "",
          format: share.exam.format,
          questions: share.exam.questions,
          question_types: share.exam.question_types
        },
        on_conflict: :nothing,
        conflict_target: [:exam_share_id, :shared_visitor_hash]
      )
    end

    Repo.one!(query) |> Repo.preload(:lesson)
  end
end

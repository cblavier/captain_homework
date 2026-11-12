defmodule CaptainHomework.ProcessingProgress do
  import Ecto.Query, only: [from: 2]
  alias CaptainHomework.Repo

  def update(source, percent, stage) do
    Repo.update_all(from(s in source.__struct__, where: s.id == ^source.id),
      set: [processing_progress: percent, processing_stage: stage]
    )

    Phoenix.PubSub.broadcast(
      CaptainHomework.PubSub,
      topic(source),
      :lesson_updated
    )

    :ok
  end

  defp topic(%{reference_exam_id: id}) when not is_nil(id), do: "reference:#{id}"
  defp topic(source), do: "lesson:#{source.lesson_id}"

  def complete(source), do: update(source, 100, nil)

  def clear(source) do
    Repo.update_all(from(s in source.__struct__, where: s.id == ^source.id),
      set: [processing_stage: nil]
    )

    Phoenix.PubSub.broadcast(
      CaptainHomework.PubSub,
      topic(source),
      :lesson_updated
    )

    :ok
  end
end

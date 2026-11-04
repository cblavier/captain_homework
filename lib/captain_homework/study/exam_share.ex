defmodule CaptainHomework.Study.ExamShare do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "exam_shares" do
    belongs_to :exam, CaptainHomework.Study.Exam
    field :token_hash, :binary
    field :mode, :string
    field :expires_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end

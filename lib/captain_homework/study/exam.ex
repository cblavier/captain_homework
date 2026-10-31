defmodule CaptainHomework.Study.Exam do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "exams" do
    belongs_to :lesson, CaptainHomework.Study.Lesson
    field :instructions, :string
    field :generation_target, :integer
    field :generation_examples, CaptainHomework.Study.JSONList, default: []
    field :generation_errors, CaptainHomework.Study.JSONList, default: []
    field :generation_started_at, :utc_datetime_usec
    field :questions, CaptainHomework.Study.JSONList, default: []
    field :answers, :map, default: %{}
    field :corrections, :map, default: %{}
    field :status, :string, default: "in_progress"
    field :score, :float
    field :submitted_at, :utc_datetime_usec
    field :grading_started_at, :utc_datetime_usec
    field :error, :string
    timestamps(type: :utc_datetime_usec)
  end
end

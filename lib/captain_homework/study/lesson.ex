defmodule CaptainHomework.Study.Lesson do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "lessons" do
    belongs_to :profile, CaptainHomework.Study.Profile
    field :subject, :string
    field :title, :string
    field :date, :date
    has_many :resources, CaptainHomework.Study.Resource
    has_many :pages, CaptainHomework.Study.Page
    has_many :exams, CaptainHomework.Study.Exam
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(lesson, attrs) do
    lesson
    |> cast(attrs, [:title, :subject, :date])
    |> validate_required([:title, :subject, :date])
    |> validate_length(:title, max: 120)
    |> validate_inclusion(:subject, CaptainHomework.Study.subject_ids())
  end
end

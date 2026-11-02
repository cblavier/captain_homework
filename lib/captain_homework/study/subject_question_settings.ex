defmodule CaptainHomework.Study.SubjectQuestionSettings do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "subject_question_settings" do
    belongs_to :profile, CaptainHomework.Study.Profile
    field :subject, :string
    field :types, CaptainHomework.Study.JSONList, default: []
    timestamps(type: :utc_datetime_usec)
  end
end

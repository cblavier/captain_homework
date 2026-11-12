defmodule CaptainHomework.Study.ReferenceExam do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "reference_exams" do
    belongs_to :profile, CaptainHomework.Study.Profile
    field :subject, :string
    field :title, :string
    field :date, :date
    has_many :pages, CaptainHomework.Study.Page
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(reference, attrs) do
    reference
    |> cast(attrs, [:title, :date])
    |> update_change(:title, &String.trim/1)
    |> validate_required([:title, :date])
    |> validate_length(:title, max: 120)
  end
end

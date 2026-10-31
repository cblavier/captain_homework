defmodule CaptainHomework.Study.Page do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "pages" do
    belongs_to :lesson, CaptainHomework.Study.Lesson
    belongs_to :resource, CaptainHomework.Study.Resource
    field :document_kind, :string, default: "other"
    field :kind, :string, default: "lesson"
    field :position, :integer, default: 0
    field :filename, :string
    field :storage_key, :string
    field :content_type, :string
    field :text, :string, default: ""
    field :status, :string, default: "pending"
    field :error, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(page, attrs) do
    page
    |> cast(attrs, [
      :resource_id,
      :document_kind,
      :kind,
      :filename,
      :storage_key,
      :content_type,
      :text,
      :status,
      :error
    ])
    |> validate_required([:kind, :filename, :storage_key, :content_type])
    |> validate_inclusion(:kind, ["lesson", "example", "resource", "illustration"])
    |> validate_length(:text, max: 60_000)
  end
end

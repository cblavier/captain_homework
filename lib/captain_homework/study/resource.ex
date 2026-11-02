defmodule CaptainHomework.Study.Resource do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "resources" do
    belongs_to :lesson, CaptainHomework.Study.Lesson
    field :filename, :string
    field :catalogue, :map
    field :catalogue_hash, :string
    field :source_url, :string
    field :storage_key, :string
    field :content_type, :string
    field :status, :string, default: "processing"
    field :processing_progress, :integer, default: 0
    field :processing_stage, :string
    field :error, :string
    field :processing_started_at, :utc_datetime_usec
    has_many :pages, CaptainHomework.Study.Page
    timestamps(type: :utc_datetime_usec)
  end
end

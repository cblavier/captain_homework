defmodule CaptainHomework.Study.Resource do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "resources" do
    belongs_to :lesson, CaptainHomework.Study.Lesson
    field :filename, :string
    field :source_url, :string
    field :storage_key, :string
    field :content_type, :string
    field :status, :string, default: "processing"
    field :error, :string
    field :processing_started_at, :utc_datetime_usec
    has_many :pages, CaptainHomework.Study.Page
    timestamps(type: :utc_datetime_usec)
  end
end

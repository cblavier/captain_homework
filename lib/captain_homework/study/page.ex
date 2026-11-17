defmodule CaptainHomework.Study.Page do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "pages" do
    belongs_to :reference_exam, CaptainHomework.Study.ReferenceExam
    belongs_to :lesson, CaptainHomework.Study.Lesson
    belongs_to :resource, CaptainHomework.Study.Resource
    belongs_to :parent_page, __MODULE__
    field :title, :string
    field :source_page_number, :integer
    field :extraction_origin, :string
    field :association_status, :string, default: "linked"
    field :legacy_hidden, :boolean, default: false
    field :ocr_status, :string, default: "pending"
    field :document_kind, :string, default: "other"
    field :style_profile, :map
    field :style_hash, :string
    field :catalogue, :map
    field :catalogue_hash, :string
    field :kind, :string, default: "lesson"
    field :extracted_from_id, :binary_id
    field :position, :integer, default: 0
    field :filename, :string
    field :storage_key, :string
    field :content_type, :string
    field :text, :string, default: ""
    field :status, :string, default: "pending"
    field :processing_progress, :integer, default: 0
    field :processing_stage, :string
    field :error, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(page, attrs) do
    page
    |> cast(attrs, [
      :resource_id,
      :title,
      :ocr_status,
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
    |> validate_length(:title, max: 240)
    |> validate_inclusion(:ocr_status, ["pending", "complete", "error"])
    |> foreign_key_constraint(:parent_page_id)
  end
end

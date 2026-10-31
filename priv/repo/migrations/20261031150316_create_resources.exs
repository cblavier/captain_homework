defmodule CaptainHomework.Repo.Migrations.CreateResources do
  use Ecto.Migration

  def change do
    create table(:resources, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :lesson_id, references(:lessons, type: :binary_id, on_delete: :delete_all), null: false
      add :filename, :string, null: false
      add :source_url, :text
      add :storage_key, :string
      add :content_type, :string
      add :status, :string, default: "processing", null: false
      add :error, :text
      add :processing_started_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:resources, [:lesson_id])

    alter table(:pages) do
      add :resource_id, references(:resources, type: :binary_id, on_delete: :delete_all)
      add :document_kind, :string, default: "other", null: false
    end

    create index(:pages, [:resource_id])
  end
end

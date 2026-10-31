defmodule CaptainHomework.Repo.Migrations.CreateStudy do
  use Ecto.Migration

  def change do
    create table(:profiles, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create table(:lessons, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :profile_id, references(:profiles, type: :binary_id, on_delete: :delete_all),
        null: false

      add :subject, :string, null: false
      add :title, :string, null: false
      add :date, :date, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:lessons, [:profile_id, :subject])

    create table(:pages, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :lesson_id, references(:lessons, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :string, null: false, default: "lesson"
      add :filename, :string, null: false
      add :storage_key, :string, null: false
      add :content_type, :string, null: false
      add :text, :text, default: "", null: false
      add :status, :string, default: "pending", null: false
      add :error, :string
      timestamps(type: :utc_datetime_usec)
    end

    create index(:pages, [:lesson_id, :kind])

    create table(:exams, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :lesson_id, references(:lessons, type: :binary_id, on_delete: :delete_all), null: false
      add :instructions, :text, null: false
      add :questions, :text, null: false
      add :answers, :map, null: false, default: %{}
      add :corrections, :map, null: false, default: %{}
      add :status, :string, null: false, default: "in_progress"
      add :score, :float
      add :submitted_at, :utc_datetime_usec
      add :grading_started_at, :utc_datetime_usec
      add :error, :string
      timestamps(type: :utc_datetime_usec)
    end

    create index(:exams, [:lesson_id, :status])
  end
end

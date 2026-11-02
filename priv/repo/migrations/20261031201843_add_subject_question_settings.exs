defmodule CaptainHomework.Repo.Migrations.AddSubjectQuestionSettings do
  use Ecto.Migration

  def change do
    create table(:subject_question_settings, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :profile_id, references(:profiles, type: :binary_id, on_delete: :delete_all),
        null: false

      add :subject, :string, null: false
      add :types, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:subject_question_settings, [:profile_id, :subject])
  end
end

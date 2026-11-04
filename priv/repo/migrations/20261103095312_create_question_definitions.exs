defmodule CaptainHomework.Repo.Migrations.CreateQuestionDefinitions do
  use Ecto.Migration

  def change do
    create table(:question_definitions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :name_key, :string, null: false
      add :subjects, :text, null: false, default: "[]"
      add :modes, :text, null: false, default: "[]"
      add :response_kind, :string, null: false
      add :instruction_kind, :string, null: false
      add :instruction, :text
      add :content_kind, :string, null: false
      add :content_presence, :string, null: false
      add :help_classic, :text
      add :help_flashcard, :text
      add :work_duration, :string, null: false
      add :example, :map, null: false, default: %{}
      add :legacy_ids, :text, null: false, default: "[]"
      add :revision, :integer, null: false, default: 1
      add :deleted_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:question_definitions, [:name_key], where: "deleted_at IS NULL")

    create table(:question_catalogue_state, primary_key: false) do
      add :id, :integer, primary_key: true
    end

    create table(:exam_question_definitions, primary_key: false) do
      add :exam_id, references(:exams, type: :binary_id, on_delete: :delete_all),
        primary_key: true

      add :definition_id,
          references(:question_definitions, type: :binary_id, on_delete: :restrict),
          primary_key: true

      add :snapshot, :map, null: false
    end
  end
end

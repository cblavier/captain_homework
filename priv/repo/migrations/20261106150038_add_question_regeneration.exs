defmodule CaptainHomework.Repo.Migrations.AddQuestionRegeneration do
  use Ecto.Migration

  def change do
    alter table(:exams) do
      add :regeneration, :map, null: false, default: %{}
      add :regeneration_source_id, references(:exams, type: :binary_id, on_delete: :delete_all)
    end

    create index(:exams, [:regeneration_source_id])
  end
end

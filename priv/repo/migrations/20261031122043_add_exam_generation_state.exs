defmodule CaptainHomework.Repo.Migrations.AddExamGenerationState do
  use Ecto.Migration

  def change do
    alter table(:exams) do
      add :generation_target, :integer
      add :generation_examples, :text, null: false, default: "[]"
      add :generation_errors, :text, null: false, default: "[]"
      add :generation_started_at, :utc_datetime_usec
    end
  end
end

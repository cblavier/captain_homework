defmodule CaptainHomework.Repo.Migrations.AddExamGenerationHistory do
  use Ecto.Migration

  def change do
    alter table(:exams) do
      add :generation_history, :text, null: false, default: "[]"
    end
  end
end

defmodule CaptainHomework.Repo.Migrations.AddExamGenerationDuration do
  use Ecto.Migration

  def change do
    alter table(:exams) do
      add :generation_duration_ms, :integer
    end
  end
end

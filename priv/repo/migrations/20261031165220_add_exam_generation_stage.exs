defmodule CaptainHomework.Repo.Migrations.AddExamGenerationStage do
  use Ecto.Migration

  def change do
    alter table(:exams) do
      add :generation_stage, :string
    end
  end
end

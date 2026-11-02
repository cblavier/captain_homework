defmodule CaptainHomework.Repo.Migrations.AddExamGenerationPlan do
  use Ecto.Migration

  def change do
    alter table(:exams) do
      add :generation_plan, :map
    end
  end
end

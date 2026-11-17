defmodule CaptainHomework.Repo.Migrations.AddGenerationRejectionsToExams do
  use Ecto.Migration

  def change do
    alter table(:exams) do
      add :generation_rejections, :text, null: false, default: "[]"
    end
  end
end

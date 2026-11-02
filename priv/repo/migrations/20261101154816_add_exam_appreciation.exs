defmodule CaptainHomework.Repo.Migrations.AddExamAppreciation do
  use Ecto.Migration

  def change do
    alter table(:exams) do
      add :appreciation, :text
    end
  end
end

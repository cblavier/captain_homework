defmodule CaptainHomework.Repo.Migrations.AddContentKindsToQuestionDefinitions do
  use Ecto.Migration

  def change do
    alter table(:question_definitions) do
      add :content_kinds, :text
    end
  end
end

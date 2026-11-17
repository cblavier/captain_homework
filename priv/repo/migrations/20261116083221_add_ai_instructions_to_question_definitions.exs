defmodule CaptainHomework.Repo.Migrations.AddAiInstructionsToQuestionDefinitions do
  use Ecto.Migration

  def change do
    alter table(:question_definitions) do
      add :ai_instructions, :text
    end
  end
end

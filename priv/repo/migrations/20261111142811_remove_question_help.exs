defmodule CaptainHomework.Repo.Migrations.RemoveQuestionHelp do
  use Ecto.Migration

  def change do
    alter table(:question_definitions) do
      remove :help_classic, :text
      remove :help_flashcard, :text
    end
  end
end

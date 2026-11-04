defmodule CaptainHomework.Repo.Migrations.UseLanguageVariableInQuestionDefaults do
  use Ecto.Migration

  def up do
    for field <- ~w(help_classic help_flashcard) do
      execute("""
      UPDATE question_definitions
      SET #{field} = 'Réponds en {langue} en une phrase.', revision = revision + 1
      WHERE #{field} = 'Réponds dans la langue étudiée en une phrase.'
      """)
    end

    execute("""
    UPDATE question_definitions
    SET instruction = 'Rédiger un court texte en {langue} à partir d’une consigne.', revision = revision + 1
    WHERE instruction = 'Rédiger un court texte dans la langue étudiée à partir d’une consigne.'
    """)
  end

  def down, do: :ok
end

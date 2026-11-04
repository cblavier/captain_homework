defmodule CaptainHomework.Repo.Migrations.EnableChronologicalOrdering do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE question_definitions
    SET response_kind = 'ordering',
        modes = CASE WHEN EXISTS (SELECT 1 FROM json_each(modes) WHERE value = 'flashcard')
          THEN modes ELSE json_insert(modes, '$[#]', 'flashcard') END,
        help_classic = CASE WHEN help_classic = 'Écris les numéros séparés par des virgules.'
          THEN NULL ELSE help_classic END,
        revision = revision + 1
    WHERE name_key = 'classement chronologique' AND deleted_at IS NULL
      AND response_kind IN ('short_text', 'long_text')
    """)
  end

  def down do
    execute("""
    UPDATE question_definitions SET response_kind = 'short_text', revision = revision + 1
    WHERE name_key = 'classement chronologique' AND response_kind = 'ordering'
    """)
  end
end

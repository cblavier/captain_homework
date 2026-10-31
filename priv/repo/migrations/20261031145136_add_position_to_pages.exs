defmodule CaptainHomework.Repo.Migrations.AddPositionToPages do
  use Ecto.Migration

  def up do
    alter table(:pages) do
      add :position, :integer, null: false, default: 0
    end

    execute("""
    WITH ranked AS (
      SELECT id, ROW_NUMBER() OVER (
        PARTITION BY lesson_id, kind ORDER BY inserted_at, id
      ) - 1 AS position FROM pages
    )
    UPDATE pages SET position = (SELECT position FROM ranked WHERE ranked.id = pages.id)
    """)
  end

  def down do
    alter table(:pages) do
      remove :position
    end
  end
end

defmodule CaptainHomework.Repo.Migrations.MoveExamplesToSubjectReferences do
  use Ecto.Migration

  def up do
    create table(:reference_exams, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :profile_id, references(:profiles, type: :binary_id, on_delete: :delete_all),
        null: false

      add :subject, :string, null: false
      add :title, :string, null: false
      add :date, :date, null: false
      timestamps(type: :utc_datetime_usec)
    end

    create index(:reference_exams, [:profile_id, :subject])

    flush()
    make_lesson_optional()

    alter table(:pages) do
      add :reference_exam_id,
          references(:reference_exams, type: :binary_id, on_delete: :delete_all)
    end

    create index(:pages, [:reference_exam_id])

    alter table(:exams) do
      add :reference_exam_id,
          references(:reference_exams, type: :binary_id, on_delete: :nilify_all)
    end

    flush()

    # The old data has no grouping beyond its lesson. Preserve every page and its order.
    execute """
    INSERT INTO reference_exams (id, profile_id, subject, title, date, inserted_at, updated_at)
    SELECT l.id, l.profile_id, l.subject, l.title, l.date, l.inserted_at, l.updated_at
    FROM lessons l WHERE EXISTS (SELECT 1 FROM pages p WHERE p.lesson_id = l.id AND p.kind = 'example')
    """

    execute "UPDATE pages SET reference_exam_id = lesson_id, lesson_id = NULL WHERE kind = 'example'"

    execute """
    UPDATE exams SET reference_exam_id = lesson_id
    WHERE EXISTS (SELECT 1 FROM reference_exams r WHERE r.id = exams.lesson_id)
      AND format = 'classic' AND generation_examples != '[]'
    """
  end

  # SQLite requires rebuilding the table to remove NOT NULL. Reuse its schema
  # and indexes so every existing field, foreign key and page ID is preserved.
  # No table has a foreign key pointing to pages.
  defp make_lesson_optional do
    [[schema]] =
      repo().query!("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'pages'").rows

    indexes =
      repo().query!(
        "SELECT sql FROM sqlite_master WHERE type = 'index' AND tbl_name = 'pages' AND sql IS NOT NULL"
      ).rows

    replacement =
      schema
      |> String.replace(~s(CREATE TABLE "pages"), ~s(CREATE TABLE "pages_rebuilt"))
      |> String.replace(~s("lesson_id" TEXT NOT NULL), ~s("lesson_id" TEXT))

    if replacement == schema, do: raise("Unexpected pages schema")
    repo().query!(replacement)
    repo().query!("INSERT INTO pages_rebuilt SELECT * FROM pages")
    repo().query!("DROP TABLE pages")
    repo().query!("ALTER TABLE pages_rebuilt RENAME TO pages")
    Enum.each(indexes, fn [sql] -> repo().query!(sql) end)
  end

  def down do
    raise "Subject references cannot be moved back into lessons without choosing a destination. Restore a backup instead."
  end
end

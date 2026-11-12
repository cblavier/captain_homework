defmodule CaptainHomework.ReferenceMigrationTest do
  use ExUnit.Case, async: false
  alias CaptainHomework.ReferenceMigrationRepo, as: Repo

  test "legacy examples are detached without losing pages, style profiles or lesson foreign keys" do
    path = Path.join(System.tmp_dir!(), "reference-migration-#{Ecto.UUID.generate()}.db")
    on_exit(fn -> Enum.each([path, path <> "-wal", path <> "-shm"], &File.rm/1) end)
    start_supervised!({Repo, database: path, pool_size: 1})
    migrations = Path.expand("../../priv/repo/migrations", __DIR__)
    Ecto.Migrator.run(Repo, migrations, :up, to: 20_261_106_150_038, log: false)

    profile = Ecto.UUID.generate()
    lesson = Ecto.UUID.generate()
    example = Ecto.UUID.generate()
    course = Ecto.UUID.generate()
    exam = Ecto.UUID.generate()
    timestamp = "2026-11-01 12:00:00.000000"

    Repo.query!(
      "INSERT INTO profiles (id, name, inserted_at, updated_at) VALUES (?, 'Alice', ?, ?)",
      [profile, timestamp, timestamp]
    )

    Repo.query!(
      "INSERT INTO lessons (id, profile_id, subject, title, date, inserted_at, updated_at) VALUES (?, ?, 'svt', 'Cellules', '2026-10-12', ?, ?)",
      [lesson, profile, timestamp, timestamp]
    )

    for {id, kind, position} <- [{example, "example", 3}, {course, "lesson", 0}] do
      Repo.query!(
        "INSERT INTO pages (id, lesson_id, kind, filename, storage_key, content_type, style_profile, position, inserted_at, updated_at) VALUES (?, ?, ?, 'page.png', 'original.png', 'image/png', '{\"readable\":true}', ?, ?, ?)",
        [id, lesson, kind, position, timestamp, timestamp]
      )
    end

    Repo.query!(
      "INSERT INTO exams (id, lesson_id, instructions, questions, generation_examples, inserted_at, updated_at) VALUES (?, ?, '', '[]', ?, ?, ?)",
      [exam, lesson, Jason.encode!([example]), timestamp, timestamp]
    )

    Ecto.Migrator.run(Repo, migrations, :up, all: true, log: false)

    assert [[^profile, "svt", "Cellules", "2026-10-12"]] =
             Repo.query!("SELECT profile_id, subject, title, date FROM reference_exams").rows

    assert [[nil, ^lesson, "original.png", 3, "{\"readable\":true}"]] =
             Repo.query!(
               "SELECT lesson_id, reference_exam_id, storage_key, position, style_profile FROM pages WHERE id = ?",
               [example]
             ).rows

    assert [[^lesson, nil]] =
             Repo.query!("SELECT lesson_id, reference_exam_id FROM pages WHERE id = ?", [course]).rows

    assert [[^lesson]] =
             Repo.query!("SELECT reference_exam_id FROM exams WHERE id = ?", [exam]).rows

    assert Repo.query!("PRAGMA foreign_key_check").rows == []
    Repo.query!("DELETE FROM lessons WHERE id = ?", [lesson])
    assert [[^example]] = Repo.query!("SELECT id FROM pages").rows
    assert Repo.query!("PRAGMA foreign_key_check").rows == []
  end
end

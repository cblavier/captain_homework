defmodule CaptainHomework.LearningPagesMigrationTest do
  use ExUnit.Case, async: false
  alias CaptainHomework.ReferenceMigrationRepo, as: Repo

  test "migration links PDF and web images, flattens crops, flags ambiguity and rolls back without losing identities" do
    path = Path.join(System.tmp_dir!(), "pages-migration-#{Ecto.UUID.generate()}.db")
    on_exit(fn -> Enum.each([path, path <> "-wal", path <> "-shm"], &File.rm/1) end)
    start_supervised!({Repo, database: path, pool_size: 1})
    migrations = Path.expand("../../priv/repo/migrations", __DIR__)
    Ecto.Migrator.run(Repo, migrations, :up, to: 20_261_111_142_811, log: false)
    # Run every pre-refactor migration even if later small changes were added.
    previous =
      Path.wildcard(Path.join(migrations, "*.exs"))
      |> Enum.map(&(&1 |> Path.basename() |> String.split("_") |> hd() |> String.to_integer()))
      |> Enum.filter(&(&1 < 20_261_113_173_107))
      |> Enum.max()

    Ecto.Migrator.run(Repo, migrations, :up, to: previous, log: false)
    profile = Ecto.UUID.generate()
    lesson = Ecto.UUID.generate()
    pdf = Ecto.UUID.generate()
    web = Ecto.UUID.generate()
    now = "2026-11-13 12:00:00.000000"

    Repo.query!("INSERT INTO profiles(id,name,inserted_at,updated_at) VALUES (?,'Alice',?,?)", [
      profile,
      now,
      now
    ])

    Repo.query!(
      "INSERT INTO lessons(id,profile_id,title,subject,date,inserted_at,updated_at) VALUES (?,?,'Chapitre','svt','2026-11-13',?,?)",
      [lesson, profile, now, now]
    )

    for {id, type} <- [{pdf, "application/pdf"}, {web, "text/html"}],
        do:
          Repo.query!(
            "INSERT INTO resources(id,lesson_id,filename,content_type,status,inserted_at,updated_at) VALUES (?,?,'document',?,'ready',?,?)",
            [id, lesson, type, now, now]
          )

    p1 = Ecto.UUID.generate()
    p2 = Ecto.UUID.generate()
    fig = Ecto.UUID.generate()
    crop = Ecto.UUID.generate()
    orphan = Ecto.UUID.generate()
    webroot = Ecto.UUID.generate()
    webimage = Ecto.UUID.generate()
    duplicate = Ecto.UUID.generate()

    rows = [
      {p1, pdf, "resource", "page-1.png", nil, "image/png"},
      {p2, pdf, "resource", "page-2.png", nil, "image/png"},
      {fig, pdf, "illustration", "page-002-figure-000.png", nil, "image/png"},
      {crop, pdf, "illustration", "crop.png", fig, "image/png"},
      {orphan, pdf, "illustration", "unknown.png", nil, "image/png"},
      {webroot, web, "resource", "Texte de la page web", nil, "text/plain"},
      {webimage, web, "resource", "carte.png", nil, "image/png"},
      {duplicate, web, "illustration", "carte.png", nil, "image/png"}
    ]

    for {id, resource, kind, name, source, type} <- rows do
      Repo.query!(
        "INSERT INTO pages(id,lesson_id,resource_id,kind,filename,storage_key,content_type,extracted_from_id,text,status,inserted_at,updated_at) VALUES (?,?,?,?,?,?,?,?,'Texte corrigé','ready',?,?)",
        [id, lesson, resource, kind, name, "#{id}.png", type, source, now, now]
      )
    end

    before =
      Repo.query!("SELECT id,kind,text,storage_key,extracted_from_id FROM pages ORDER BY id").rows

    Ecto.Migrator.run(Repo, migrations, :up, to: 20_261_113_173_107, log: false)

    assert [[^p2], [^p2]] =
             Repo.query!("SELECT parent_page_id FROM pages WHERE id IN (?,?) ORDER BY id", [
               fig,
               crop
             ]).rows

    assert [["unresolved", nil]] =
             Repo.query!("SELECT association_status,parent_page_id FROM pages WHERE id=?", [
               orphan
             ]).rows

    assert [["illustration", ^webroot, "Texte corrigé"]] =
             Repo.query!("SELECT kind,parent_page_id,text FROM pages WHERE id=?", [webimage]).rows

    assert [[1]] = Repo.query!("SELECT legacy_hidden FROM pages WHERE id=?", [duplicate]).rows
    assert Repo.query!("PRAGMA foreign_key_check").rows == []
    Ecto.Migrator.run(Repo, migrations, :down, step: 1, log: false)

    assert before ==
             Repo.query!(
               "SELECT id,kind,text,storage_key,extracted_from_id FROM pages ORDER BY id"
             ).rows

    assert Repo.query!("PRAGMA foreign_key_check").rows == []
  end
end

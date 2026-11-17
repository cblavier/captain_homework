defmodule CaptainHomework.LearningPagesTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Repo, Study}
  alias CaptainHomework.Study.Pages

  test "drag order persists and cannot cross chapter or page kind" do
    l = lesson(profile())
    a = page(l)
    b = page(l)
    c = page(l)
    assert {:ok, _} = Study.reorder_page(l.profile_id, l.id, c.id, a.id)
    assert Enum.map(Study.get_lesson!(l.profile_id, l.id).pages, & &1.id) == [c.id, a.id, b.id]
    assert {:ok, _} = Study.reorder_page(l.profile_id, l.id, c.id, nil)
    assert Enum.map(Study.get_lesson!(l.profile_id, l.id).pages, & &1.id) == [a.id, b.id, c.id]
    other = page(lesson(profile("Bob")))
    assert {:error, :not_found} = Study.reorder_page(l.profile_id, l.id, a.id, other.id)
    resource = page(l) |> Ecto.Changeset.change(kind: "resource") |> Repo.update!()
    assert {:error, :not_found} = Study.reorder_page(l.profile_id, l.id, a.id, resource.id)
  end

  test "OCR titles replace default names but preserve manual names and stale rename races" do
    l = lesson(profile())
    pg = page(l)
    Pages.suggest_name(pg, "La cellule animale")
    assert Repo.get!(Study.Page, pg.id).title == "La cellule animale"
    {:ok, _} = Pages.rename(l.profile_id, l.id, pg.id, %{title: "Mon cours"})
    Pages.suggest_name(pg, "Un titre tardif")
    assert Repo.get!(Study.Page, pg.id).title == "Mon cours"
    Pages.suggest_name(Repo.get!(Study.Page, pg.id), "Un autre titre")
    assert Repo.get!(Study.Page, pg.id).title == "Mon cours"
  end

  test "illustration names use their own analysis with a default fallback" do
    l = lesson(profile())
    parent = page(l)

    {:ok, illustration} =
      Study.add_page(
        l,
        %{
          kind: "illustration",
          title: "Illustration 1",
          filename: "figure.png",
          storage_key: "figure.png",
          content_type: "image/png",
          status: "ready"
        },
        parent_page_id: parent.id
      )

    Pages.suggest_name(illustration, "  La membrane   cellulaire  ")
    assert Repo.get!(Study.Page, illustration.id).title == "La membrane cellulaire"
    {:ok, renamed} = Pages.rename(l.profile_id, l.id, illustration.id, %{title: "Mon schéma"})
    Pages.suggest_name(renamed, "Autre suggestion")
    assert Repo.get!(Study.Page, illustration.id).title == "Mon schéma"
    assert Pages.suggested_name(nil, "Illustration 2") == "Illustration 2"
    assert Pages.suggested_name("  ", "Illustration 2") == "Illustration 2"
    assert Pages.suggested_name("  Carte de Shanghai ", "Illustration 2") == "Carte de Shanghai"
  end

  test "new illustrations require a direct original in the same chapter and import" do
    lesson = lesson(profile())
    parent = page(lesson)

    attrs = %{
      kind: "illustration",
      filename: "figure.png",
      storage_key: "fixture.png",
      content_type: "image/png",
      status: "ready"
    }

    assert {:error, _} = Study.add_page(lesson, attrs)
    assert {:ok, child} = Study.add_page(lesson, attrs, parent_page_id: parent.id)
    assert {:error, _} = Study.add_page(lesson, attrs, parent_page_id: child.id)
    foreign = page(lesson(profile("Bob")))
    assert {:error, _} = Study.add_page(lesson, attrs, parent_page_id: foreign.id)

    assert {:ok, renamed} =
             Pages.rename(lesson.profile_id, lesson.id, child.id, %{title: "La membrane"})

    assert renamed.id == child.id
    assert renamed.parent_page_id == parent.id
    assert renamed.filename == child.filename
    assert {:error, _} = Pages.rename(lesson.profile_id, lesson.id, child.id, %{title: " "})
  end

  test "a lesson original and its illustration are eligible visual supports in the catalogue" do
    lesson = lesson(profile())
    root = page(lesson)

    {:ok, illustration} =
      Study.add_page(
        lesson,
        %{
          kind: "illustration",
          filename: "figure.png",
          storage_key: "figure.png",
          content_type: "image/png",
          status: "ready",
          text: "Le noyau"
        },
        parent_page_id: root.id
      )

    catalogue = %{
      "entries" => [
        %{
          "kind" => "knowledge",
          "title" => "La cellule",
          "content" => "Une cellule contient un noyau.",
          "keywords" => ["cellule"],
          "usable" => true,
          "source_page_ids" => [root.id, illustration.id],
          "visual_page_ids" => [root.id, illustration.id]
        }
      ]
    }

    assert :ok = CaptainHomework.Catalogues.validate(catalogue, [root, illustration])
  end

  test "unresolved legacy illustrations can be explicitly attached without changing identity or OCR" do
    lesson = lesson(profile())
    root = page(lesson)

    unresolved =
      Repo.insert!(%Study.Page{
        lesson_id: lesson.id,
        kind: "illustration",
        title: "Ancien schéma",
        association_status: "unresolved",
        filename: "old.png",
        storage_key: "not-a-file.png",
        content_type: "image/png",
        text: "Légende conservée",
        status: "ready"
      })

    loaded = Study.get_lesson!(lesson.profile_id, lesson.id)

    refute Enum.any?(
             CaptainHomework.Exams.Illustrations.content_pages(loaded),
             &(&1.id == unresolved.id)
           )

    assert {:ok, attached} = Pages.attach(lesson.profile_id, lesson.id, unresolved.id, root.id)
    assert attached.id == unresolved.id
    assert attached.text == unresolved.text
    assert attached.parent_page_id == root.id
    assert attached.association_status == "linked"

    assert {:error, :invalid_parent} =
             Pages.attach(lesson.profile_id, lesson.id, unresolved.id, root.id)

    loaded = Study.get_lesson!(lesson.profile_id, lesson.id)

    assert Enum.any?(
             CaptainHomework.Exams.Illustrations.content_pages(loaded),
             &(&1.id == unresolved.id)
           )
  end
end

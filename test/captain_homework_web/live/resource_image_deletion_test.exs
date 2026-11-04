defmodule CaptainHomeworkWeb.ResourceImageDeletionTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Repo, Resources, Study, Uploads}

  setup do
    previous = Application.fetch_env(:captain_homework, :uploads_dir)
    dir = Path.join(System.tmp_dir!(), "resource-delete-#{Ecto.UUID.generate()}")
    File.mkdir_p!(dir)
    Application.put_env(:captain_homework, :uploads_dir, dir)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:captain_homework, :uploads_dir, value)
        :error -> Application.delete_env(:captain_homework, :uploads_dir)
      end

      File.rm_rf(dir)
    end)

    l = lesson(profile())

    r =
      Repo.insert!(%Study.Resource{
        lesson_id: l.id,
        filename: "source.png",
        status: "ready",
        storage_key: "original.png",
        content_type: "image/png",
        catalogue: %{"entries" => []},
        catalogue_hash: "old"
      })

    File.write!(Uploads.path("original.png"), "original")

    pages =
      for {kind, key, data} <- [
            {"resource", "page.png", "same-image"},
            {"illustration", "image.png", "same-image"},
            {"illustration", "other.png", "other-image"}
          ] do
        File.write!(Uploads.path(key), data)

        {:ok, page} =
          Study.add_page(l, %{
            resource_id: r.id,
            kind: kind,
            filename: key,
            storage_key: key,
            content_type: "image/png",
            text: "Texte reconnu",
            status: "ready"
          })

        page
      end

    %{lesson: l, resource: r, pages: pages}
  end

  test "deleting an image refreshes its resource and removes its identical OCR copy", %{
    conn: conn,
    lesson: l,
    resource: r,
    pages: [ocr, image, other]
  } do
    File.write!(Uploads.path("exam-snapshot.png"), "same-image")
    e = exam(l, [Map.put(question(), "images", [%{"storage_key" => "exam-snapshot.png"}])])
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}?onglet=ressources")
    assert has_element?(view, "#resource-image-#{image.id}")
    view |> element("#delete-resource-image-#{image.id}") |> render_click()
    refute has_element?(view, "#resource-image-#{image.id}")
    refute has_element?(view, "#delete-resource-page-#{ocr.id}")
    assert has_element?(view, "#resource-image-#{other.id}")
    assert Repo.get(Study.Page, image.id) == nil
    assert Repo.get(Study.Page, ocr.id) == nil
    refute File.exists?(Uploads.path(image.storage_key))
    refute File.exists?(Uploads.path(ocr.storage_key))
    assert File.exists?(Uploads.path(r.storage_key))
    assert Repo.get!(Study.Resource, r.id).catalogue == nil
    assert Repo.get!(Study.Resource, r.id).catalogue_hash == nil
    assert Repo.get!(Study.Exam, e.id).questions == e.questions
    assert File.read!(Uploads.path("exam-snapshot.png")) == "same-image"
    sources = CaptainHomework.Exams.Illustrations.sources(Study.get_lesson!(l.profile_id, l.id))
    refute Enum.any?(sources, &(&1.id in [ocr.id, image.id]))
  end

  test "resource illustrations share compact cards and reorder only within their resource", %{
    conn: conn,
    lesson: lesson,
    resource: resource,
    pages: [_, first, second]
  } do
    other_resource =
      Repo.insert!(%Study.Resource{lesson_id: lesson.id, filename: "Other.png", status: "ready"})

    other =
      Repo.insert!(%Study.Page{
        lesson_id: lesson.id,
        resource_id: other_resource.id,
        kind: "illustration",
        filename: "other.png",
        storage_key: "other.png",
        content_type: "image/png",
        status: "ready",
        position: 99
      })

    {:ok, view, _} = live(conn, "/alice/lecons/#{lesson.id}?onglet=ressources")

    assert has_element?(
             view,
             "#resource-image-#{first.id}.page-card .page-thumbnail #resource-image-previous-#{first.id}[disabled]"
           )

    view |> element("#resource-image-next-#{first.id}") |> render_click()
    assert has_element?(view, "#resource-image-previous-#{second.id}[disabled]")
    assert has_element?(view, "#resource-image-next-#{first.id}[disabled]")
    assert Repo.get!(Study.Page, other.id).position == 99
    assert {:ok, _} = Study.move_page(lesson.profile_id, lesson.id, first.id, "next")
    assert Repo.get!(Study.Page, other.id).position == 99
    resource |> Ecto.Changeset.change(processing_stage: "Analyse") |> Repo.update!()

    assert {:error, :unavailable} =
             Study.move_page(lesson.profile_id, lesson.id, first.id, "previous")
  end

  test "only images of the current profile and lesson can be deleted", %{
    lesson: l,
    pages: [_, image, _]
  } do
    assert {:error, :not_found} = Resources.delete_image(Ecto.UUID.generate(), l.id, image.id)

    assert {:error, :not_found} =
             Resources.delete_image(l.profile_id, Ecto.UUID.generate(), image.id)

    assert Repo.get!(Study.Page, image.id)
    assert File.exists?(Uploads.path(image.storage_key))
  end

  test "resource processing prevents deletion", %{
    conn: conn,
    lesson: l,
    resource: r,
    pages: [_, image, _]
  } do
    Repo.update!(Ecto.Changeset.change(r, status: "processing"))
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}?onglet=ressources")
    assert has_element?(view, "#delete-resource-image-#{image.id}[disabled]")
    assert {:error, _} = Resources.delete_image(l.profile_id, l.id, image.id)
    assert Repo.get!(Study.Page, image.id)
  end

  test "deleting the last imported page preserves the original resource", %{
    lesson: l,
    resource: r,
    pages: [ocr, _, other]
  } do
    assert {:ok, _} = Resources.delete_image(l.profile_id, l.id, other.id)
    assert {:ok, _} = Resources.delete_image(l.profile_id, l.id, ocr.id)
    assert Study.get_lesson!(l.profile_id, l.id).pages == []
    assert Repo.get!(Study.Resource, r.id)
    assert File.exists?(Uploads.path(r.storage_key))
  end
end

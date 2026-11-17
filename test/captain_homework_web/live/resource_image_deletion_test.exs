defmodule CaptainHomeworkWeb.ResourceImageDeletionTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Ecto.Query
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
          Study.add_page(
            l,
            %{
              resource_id: r.id,
              kind: kind,
              filename: key,
              storage_key: key,
              content_type: "image/png",
              text: "Texte reconnu",
              status: "ready"
            },
            parent_page_id:
              if(kind == "illustration",
                do:
                  Repo.one!(
                    from p in Study.Page, where: p.lesson_id == ^l.id and p.kind == "resource"
                  ).id
              )
          )

        page
      end

    %{lesson: l, resource: r, pages: pages}
  end

  test "deleting an illustration preserves original OCR, siblings and exam snapshots", %{
    conn: conn,
    lesson: l,
    resource: r,
    pages: [ocr, image, other]
  } do
    File.write!(Uploads.path("exam-snapshot.png"), "same-image")
    e = exam(l, [Map.put(question(), "images", [%{"storage_key" => "exam-snapshot.png"}])])
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}?onglet=ressources&page=#{ocr.id}")
    assert has_element?(view, "#resource-image-#{image.id}")
    view |> element("#delete-resource-image-#{image.id}") |> render_click()
    refute has_element?(view, "#resource-image-#{image.id}")
    assert has_element?(view, "#resource-image-#{other.id}")
    assert Repo.get(Study.Page, image.id) == nil
    assert Repo.get!(Study.Page, ocr.id).text == ocr.text
    refute File.exists?(Uploads.path(image.storage_key))
    assert File.exists?(Uploads.path(ocr.storage_key))
    assert File.exists?(Uploads.path(r.storage_key))
    assert Repo.get!(Study.Resource, r.id).catalogue == nil
    assert Repo.get!(Study.Exam, e.id).questions == e.questions
    assert File.read!(Uploads.path("exam-snapshot.png")) == "same-image"
  end

  test "compact cards reorder only within their parent page and zoom has no extraction action", %{
    conn: conn,
    lesson: lesson,
    pages: [root, first, second]
  } do
    other_root = page(lesson)

    other =
      Repo.insert!(%Study.Page{
        lesson_id: lesson.id,
        parent_page_id: other_root.id,
        kind: "illustration",
        filename: "other.png",
        storage_key: "other.png",
        content_type: "image/png",
        status: "ready",
        position: 99
      })

    {:ok, view, _} = live(conn, "/alice/lecons/#{lesson.id}?onglet=ressources&page=#{root.id}")

    assert has_element?(
             view,
             "#resource-image-#{first.id}.page-card .learning-card-footer #resource-image-previous-#{first.id}[disabled]"
           )

    view |> element("#resource-image-next-#{first.id}") |> render_click()
    assert has_element?(view, "#resource-image-previous-#{second.id}[disabled]")
    assert has_element?(view, "#resource-image-next-#{first.id}[disabled]")
    assert Repo.get!(Study.Page, other.id).position == 99
    view |> element("#open-resource-image-#{first.id}") |> render_click()
    assert has_element?(view, "#source-modal img[src='/alice/pages/#{first.id}']")
    refute has_element?(view, "#source-modal [phx-click=extract_page]")
    refute has_element?(view, "#extract-illustrations-modal")
  end

  test "legacy orphan stays visible and can be attached through the page picker", %{
    conn: conn,
    lesson: l,
    pages: [root, image, _]
  } do
    image
    |> Ecto.Changeset.change(parent_page_id: nil, association_status: "unresolved")
    |> Repo.update!()

    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}?onglet=ressources")
    assert has_element?(view, "#unresolved-pages")
    view |> element("#attach-illustration-#{image.id}") |> render_click()

    view
    |> form("#attach-illustration-form", attachment: %{parent_page_id: root.id})
    |> render_submit()

    refute has_element?(view, "#attach-illustration-modal")
    refute has_element?(view, "#unresolved-pages")
    assert Repo.get!(Study.Page, image.id).parent_page_id == root.id
    view |> element("#open-page-#{root.id}") |> render_click()
    assert has_element?(view, "#resource-image-#{image.id}")
  end

  test "only illustrations of the current profile and lesson can be deleted", %{
    lesson: l,
    pages: [root, image, _]
  } do
    assert {:error, :not_found} = Resources.delete_image(Ecto.UUID.generate(), l.id, image.id)

    assert {:error, :not_found} =
             Resources.delete_image(l.profile_id, Ecto.UUID.generate(), image.id)

    assert {:error, :not_found} = Resources.delete_image(l.profile_id, l.id, root.id)
    assert Repo.get!(Study.Page, image.id)
    assert File.exists?(Uploads.path(image.storage_key))
  end

  test "resource processing prevents deletion", %{
    conn: conn,
    lesson: l,
    resource: r,
    pages: [root, image, _]
  } do
    Repo.update!(Ecto.Changeset.change(r, status: "processing"))
    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}?onglet=ressources&page=#{root.id}")
    assert has_element?(view, "#delete-resource-image-#{image.id}[disabled]")
    assert {:error, _} = Resources.delete_image(l.profile_id, l.id, image.id)
    assert Repo.get!(Study.Page, image.id)
  end

  test "deleting a page deletes its illustrations and releases an empty import", %{
    lesson: l,
    resource: r,
    pages: [root | children]
  } do
    assert {:ok, _} = Study.delete_page(root)
    assert Study.get_lesson!(l.profile_id, l.id).pages == []
    refute Repo.get(Study.Resource, r.id)
    refute File.exists?(Uploads.path(r.storage_key))
    for child <- children, do: refute(File.exists?(Uploads.path(child.storage_key)))
  end
end

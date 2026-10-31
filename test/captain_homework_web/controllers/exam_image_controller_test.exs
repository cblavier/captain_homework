defmodule CaptainHomeworkWeb.ExamImageControllerTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import CaptainHomework.Fixtures
  import Phoenix.LiveViewTest
  alias CaptainHomework.{Repo, Uploads}

  test "the original illustration is rendered in both exercise and corrected copy", %{conn: conn} do
    l = lesson(profile())
    image_id = Ecto.UUID.generate()

    q =
      Map.put(question(), "images", [
        %{"id" => image_id, "storage_key" => "snapshot.png", "content_type" => "image/png"}
      ])

    e = exam(l, [q])
    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
    selector = "#question-image-q1-#{image_id}[src='/alice/controles/#{e.id}/images/#{image_id}']"
    assert has_element?(view, selector)
    assert has_element?(view, ".question-illustrations #{selector}")

    Repo.update!(
      Ecto.Changeset.change(e,
        status: "completed",
        score: 20.0,
        submitted_at: DateTime.utc_now(),
        corrections: %{"q1" => %{"fraction" => 1.0, "points" => 4.0, "feedback" => "Bravo"}}
      )
    )

    {:ok, corrected, _} = live(conn, "/alice/controles/#{e.id}")
    assert has_element?(corrected, selector)
  end

  test "original illustrations require the owning child and exam", %{conn: conn} do
    l = lesson(profile())
    id = Ecto.UUID.generate()
    key = "question-#{id}.png"
    File.mkdir_p!(Uploads.directory())
    File.write!(Uploads.path(key), "original bytes")
    on_exit(fn -> File.rm(Uploads.path(key)) end)

    q =
      Map.put(question(), "images", [
        %{"id" => id, "storage_key" => key, "content_type" => "image/png"}
      ])

    e = exam(l, [q])
    assert get(conn, "/alice/controles/#{e.id}/images/#{id}").resp_body == "original bytes"
    assert_error_sent 404, fn -> get(conn, "/marius/controles/#{e.id}/images/#{id}") end
    other = exam(l)
    assert get(conn, "/alice/controles/#{other.id}/images/#{id}").status == 404
    Repo.delete!(e)
    assert_error_sent 404, fn -> get(conn, "/alice/controles/#{e.id}/images/#{id}") end
  end
end

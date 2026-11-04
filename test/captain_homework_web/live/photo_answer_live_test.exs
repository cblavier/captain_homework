defmodule CaptainHomeworkWeb.PhotoAnswerLiveTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Study, Uploads}

  test "webcam capture is available for drawing and transcribed answers", %{conn: conn} do
    e = exam(lesson(profile()), [question("q1", "photo"), question("q2")])
    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")

    assert has_element?(view, "#webcam-q1[data-upload-name='drawing-#{e.id}-q1']")
    assert has_element?(view, "#webcam-q1 dialog video[playsinline]")
    assert has_element?(view, "#webcam-q1 [data-camera-use][hidden]")

    view |> element("button[phx-click=open_ocr][phx-value-id=q2]") |> render_click()
    assert has_element?(view, "#webcam-answer-photo[data-upload-name=answer_photo]")
    assert has_element?(view, "#answer-photo-form input[type=file]")
  end

  test "the corrected copy displays the photo without editable actions or storage metadata", %{
    conn: conn
  } do
    e = exam(lesson(profile()), [question("q1", "photo")])

    asset = %{
      "id" => Ecto.UUID.generate(),
      "storage_key" => "private-drawing.png",
      "content_type" => "image/png",
      "filename" => "triangle.png"
    }

    CaptainHomework.Repo.update!(
      Ecto.Changeset.change(e,
        status: "completed",
        score: 20.0,
        submitted_at: DateTime.utc_now(),
        answers: %{"q1" => asset},
        corrections: %{
          "q1" => %{
            "fraction" => 1,
            "points" => 4,
            "expected" => "Triangle rectangle",
            "feedback" => "Correct",
            "language_errors" => []
          }
        }
      )
    )

    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")

    assert has_element?(
             view,
             "#photo-response-q1 img[src='/alice/controles/#{e.id}/images/#{asset["id"]}']"
           )

    refute has_element?(view, "#webcam-q1")
    refute has_element?(view, "#choose-photo-q1")
    refute has_element?(view, "#remove-photo-q1")
    refute has_element?(view, "#student-answer-q1")
  end

  test "submission confirmation counts saved photos along with form answers", %{conn: conn} do
    e = exam(lesson(profile()), [question("text"), question("photo", "photo")])

    asset = %{
      "id" => Ecto.UUID.generate(),
      "storage_key" => "drawing.png",
      "content_type" => "image/png",
      "filename" => "triangle.png"
    }

    CaptainHomework.Repo.update!(Ecto.Changeset.change(e, answers: %{"photo" => asset}))
    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
    view |> form("#exam-answers", answers: %{"text" => "Une limite"}) |> render_submit()
    assert has_element?(view, "#submit-confirm", "2 réponses sur 2")
    assert has_element?(view, "#photo-response-photo img")
    saved = Study.get_exam!(profile().id, e.id)
    assert saved.answers == %{"text" => "Une limite", "photo" => asset}
    assert saved.status == "in_progress"
  end

  test "each question saves its own photo automatically and allows replacement", %{conn: conn} do
    e = exam(lesson(profile()), [question("q1", "photo"), question("q2", "photo")])
    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")

    for {question_id, filename} <- [{"q2", "second.png"}, {"q1", "first.png"}, {"q2", "new.png"}] do
      upload =
        file_input(view, "#exam-answers", "drawing-#{e.id}-#{question_id}", [
          %{
            name: filename,
            content: <<137, 80, 78, 71, 13, 10, 26, 10>> <> :binary.copy(<<0>>, 92),
            type: "image/png"
          }
        ])

      render_upload(upload, filename, 50)
      assert has_element?(view, "#finish-exam[disabled]")
      assert has_element?(view, "#photo-response-#{question_id} [role=status]")
      render_upload(upload, filename, 50)
      refute has_element?(view, "#finish-exam[disabled]")
      asset = Study.get_exam!(profile().id, e.id).answers[question_id]
      assert asset["filename"] == filename
      on_exit(fn -> File.rm(Uploads.path(asset["storage_key"])) end)
    end

    saved = Study.get_exam!(profile().id, e.id)
    assert saved.answers["q1"]["filename"] == "first.png"
    assert saved.answers["q2"]["filename"] == "new.png"
    view |> element("#remove-photo-q2") |> render_click()
    assert Study.get_exam!(profile().id, e.id).answers["q1"] == saved.answers["q1"]
    refute has_element?(view, "#photo-response-q2 img[src]")
  end

  test "upload a drawing, reload, access the protected image and remove it", %{conn: conn} do
    e = exam(lesson(profile()), [question("q1", "photo")])
    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
    assert has_element?(view, "#choose-photo-q1 input[type=file]:not([capture])")
    refute has_element?(view, "#drawing-photo-form")

    upload =
      file_input(view, "#exam-answers", "drawing-#{e.id}-q1", [
        %{
          name: "triangle.png",
          content: <<137, 80, 78, 71, 13, 10, 26, 10, 0>>,
          type: "image/png"
        }
      ])

    render_upload(upload, "triangle.png")
    saved = Study.get_exam!(profile().id, e.id)
    asset = saved.answers["q1"]
    assert is_map(asset)
    on_exit(fn -> File.rm(Uploads.path(asset["storage_key"])) end)
    {:ok, reloaded, _} = live(conn, "/alice/controles/#{e.id}")
    url = "/alice/controles/#{e.id}/images/#{asset["id"]}"
    assert has_element?(reloaded, "#photo-response-q1 img[src='#{url}']")
    response = get(conn, url)
    assert response.status == 200
    assert get_resp_header(response, "cache-control") == ["private, no-store"]
    assert_error_sent 404, fn -> get(conn, "/marius/controles/#{e.id}/images/#{asset["id"]}") end
    reloaded |> element("#remove-photo-q1") |> render_click()
    assert Study.get_exam!(profile().id, e.id).answers["q1"] == ""
    assert get(conn, url).status == 404
  end
end

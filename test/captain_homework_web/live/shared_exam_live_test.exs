defmodule CaptainHomeworkWeb.SharedExamLiveTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.{ExamShares, Exams, Repo, Study, Uploads}

  setup do
    previous =
      Map.new(
        [:ai_provider, :grading_test_pid],
        &{&1, Application.fetch_env(:captain_homework, &1)}
      )

    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.TestAI)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, old} -> Application.put_env(:captain_homework, key, old)
          :error -> Application.delete_env(:captain_homework, key)
        end
      end
    end)

    p = profile()
    %{profile: p, exam: exam(lesson(p))}
  end

  test "both share modes use the originating student's theme", %{conn: conn} do
    owner = profile("Marius")
    control = exam(lesson(owner))
    {:ok, _} = Exams.submit(owner.id, control.id, %{"q1" => "quart"}, sync: true)

    for mode <- ["fill", "correction"] do
      {:ok, _, token} = ExamShares.create(owner.id, control.id, mode)
      {:ok, view, _} = live(conn, "/partage/#{token}")
      assert has_element?(view, ".page-shell[data-child-theme='#{owner.theme}'] #exam-title")
    end
  end

  test "the footer opens both choices and a copyable unique URL", %{
    conn: conn,
    profile: p,
    exam: e
  } do
    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
    view |> element("#exam-footer #share-exam") |> render_click()
    assert has_element?(view, "#share-exam-modal[role=dialog]")
    assert has_element?(view, "#share-correction[disabled]")
    view |> element("#share-fill") |> render_click()
    assert has_element?(view, "#share-url[readonly]")
    assert has_element?(view, "#copy-share-url")

    [url] =
      view
      |> element("#share-url")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("value")

    assert {:ok, %{mode: "fill"}} = ExamShares.fetch(List.last(String.split(url, "/")))

    {:ok, _} = Exams.submit(p.id, e.id, %{"q1" => "quart"}, sync: true)
    send(view.pid, :refresh_exam)
    refute has_element?(view, "#share-correction[disabled]")
    view |> element("#share-correction") |> render_click()

    [url] =
      view
      |> element("#share-url")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("value")

    assert {:ok, %{mode: "correction"}} = ExamShares.fetch(List.last(String.split(url, "/")))
  end

  test "a guest submits a separate copy and gets a generic correction without application navigation",
       %{profile: p, exam: e} do
    conn = Phoenix.ConnTest.build_conn()
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.BlockingGradeAI)
    Application.put_env(:captain_homework, :grading_test_pid, self())
    {:ok, _, token} = ExamShares.create(p.id, e.id, "fill")
    conn = get(conn, "/partage/#{token}")
    visitor = get_session(conn, :shared_visitor)
    assert get_session(conn, :access) == nil
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
    assert get_resp_header(conn, "referrer-policy") == ["no-referrer"]
    {:ok, view, _} = live(conn)
    refute has_element?(view, "#child-picker")
    refute has_element?(view, ".page-breadcrumb")
    refute has_element?(view, "a[href]")
    refute has_element?(view, "#delete-exam")
    refute has_element?(view, "#share-exam")
    assert has_element?(view, "#exam-title", "Contrôle de #{Study.subject!("svt").name}")
    assert has_element?(view, "#shared-exam-subject-icon.green .icon")
    assert has_element?(view, "#shared-exam-lesson.muted", "La cellule")
    {:ok, _, attempt} = ExamShares.open(token, visitor)

    render_click(view, "delete_exam", %{})
    render_click(view, "open_source", %{"id" => Ecto.UUID.generate()})
    render_click(view, "create_lesson", %{"lesson" => %{"title" => "Forbidden"}})
    assert Repo.get(Study.Exam, e.id)
    refute has_element?(view, "#source-modal")

    view |> form("#exam-answers", answers: %{"q1" => "quart"}) |> render_submit()
    assert has_element?(view, "#submit-confirm", "1 réponses sur 1")
    view |> element("#submit-confirm button[phx-click=submit_exam]") |> render_click()
    assert_receive {:grading_waiting, worker}
    on_exit(fn -> send(worker, :fail_grading) end)
    ref = Process.monitor(worker)
    assert has_element?(view, "#exam-answers fieldset[disabled]")
    send(worker, :finish_grading)
    assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 2000
    send(view.pid, :refresh_exam)
    assert has_element?(view, "#student-answer-q1", "Réponse de l’élève")
    assert has_element?(view, ".total-score", "5")
    refute has_element?(view, "#question-sources-q1")
    refute has_element?(view, "#finish-exam")
    assert Study.get_exam!(p.id, e.id).answers == %{}
    assert Study.get_exam!({:shared, token, visitor}, attempt.id).score == 5.0

    {:ok, reloaded, _} = conn |> recycle() |> live("/partage/#{token}")
    assert has_element?(reloaded, ".total-score", "5")
    assert redirected_to(conn |> recycle() |> get("/alice/controles/#{e.id}")) == "/connexion"
  end

  test "correction shares are read-only and expired links stop an already open form", %{
    conn: conn,
    profile: p,
    exam: e
  } do
    {:ok, _} = Exams.submit(p.id, e.id, %{"q1" => "quart"}, sync: true)
    {:ok, _, correction} = ExamShares.create(p.id, e.id, "correction")
    {:ok, view, _} = live(conn, "/partage/#{correction}")
    assert has_element?(view, "#student-answer-q1", "quart")
    assert has_element?(view, "#student-answer-q1 strong", "Réponse de #{p.name}")
    assert has_element?(view, "#shared-exam-subject-icon.green .icon")
    assert has_element?(view, "#shared-exam-lesson", "La cellule")
    refute has_element?(view, "a[href]")
    render_change(view, "save_answers", %{"answers" => %{"q1" => "faux"}})
    render_click(view, "redo_exam", %{})
    render_click(view, "open_share", %{})
    assert Study.get_exam!(p.id, e.id).answers == %{"q1" => "quart"}
    refute has_element?(view, "#share-exam-modal")

    {:ok, share, token} = ExamShares.create(p.id, e.id, "fill")
    {:ok, fill, _} = live(conn, "/partage/#{token}")
    Repo.update!(Ecto.Changeset.change(share, expires_at: DateTime.add(DateTime.utc_now(), -1)))
    fill |> form("#exam-answers", answers: %{"q1" => "faux"}) |> render_change()
    assert has_element?(fill, "#share-unavailable")
    refute has_element?(fill, "#exam-answers")
    {:ok, expired, _} = live(conn, "/partage/#{token}")
    assert has_element?(expired, "#share-unavailable")
    {:ok, invalid, _} = live(conn, "/partage/invalid")
    assert has_element?(invalid, "#share-unavailable")
  end

  test "public photos belong to the current visitor and no source page can be fetched", %{
    conn: conn,
    profile: p
  } do
    e = exam(lesson(p), [question("photo", "photo")])
    {:ok, _, token} = ExamShares.create(p.id, e.id, "fill")
    conn = get(conn, "/partage/#{token}")
    {:ok, _, attempt} = ExamShares.open(token, get_session(conn, :shared_visitor))
    {:ok, view, _} = live(conn)

    upload =
      file_input(view, "#exam-answers", "drawing-#{attempt.id}-photo", [
        %{
          name: "drawing.png",
          content: <<137, 80, 78, 71, 13, 10, 26, 10, 0>>,
          type: "image/png"
        }
      ])

    render_upload(upload, "drawing.png")
    asset = Repo.get!(Study.Exam, attempt.id).answers["photo"]
    on_exit(fn -> File.rm(Uploads.path(asset["storage_key"])) end)
    path = "/partage/#{token}/images/#{asset["id"]}"
    assert has_element?(view, "#photo-response-photo img[src='#{path}']")
    assert (conn |> recycle() |> get(path)).status == 200
    assert get(build_conn(), path).status == 404
    assert get(build_conn(), "/partage/#{token}/images/#{e.lesson_id}").status == 404
    assert Study.get_exam!(p.id, e.id).answers == %{}
  end

  test "flashcards can be shared before completion and guests stay in the control", %{
    conn: conn,
    profile: p,
    exam: e
  } do
    e =
      Repo.update!(
        Ecto.Changeset.change(e, format: "flashcard", questions: [question("q1", "definition")])
      )

    {:ok, owner, _} = live(conn, "/alice/controles/#{e.id}")
    owner |> element("#flashcard-session #share-exam") |> render_click()
    assert has_element?(owner, "#share-exam-modal")
    {:ok, _, token} = ExamShares.create(p.id, e.id, "fill")
    conn = get(conn, "/partage/#{token}")
    {:ok, _, attempt} = ExamShares.open(token, get_session(conn, :shared_visitor))
    {:ok, view, _} = live(conn)
    refute has_element?(view, "#close-flashcards")
    assert has_element?(view, "#flashcard-answer")

    {:ok, _} =
      Exams.Flashcards.submit(
        {:shared, token, get_session(conn, :shared_visitor)},
        attempt.id,
        "q1",
        "quart",
        sync: true
      )

    send(view.pid, :refresh_exam)
    assert has_element?(view, "#flashcard-correction")
    view |> element("#next-card") |> render_click()
    assert has_element?(view, ".total-score", "5")
    refute has_element?(view, "#child-picker")
    refute has_element?(view, "a[href]")
  end

  test "only this control's illustrations and audio are available, until expiration", %{
    conn: conn,
    profile: p
  } do
    key = "shared-media-#{Ecto.UUID.generate()}.png"
    File.mkdir_p!(Uploads.directory())
    File.write!(Uploads.path(key), "media")
    on_exit(fn -> File.rm(Uploads.path(key)) end)
    image = %{"id" => Ecto.UUID.generate(), "storage_key" => key, "content_type" => "image/png"}
    audio = %{"id" => Ecto.UUID.generate(), "storage_key" => key, "content_type" => "audio/mpeg"}
    q = question("listening", "listening") |> Map.merge(%{"images" => [image], "audio" => audio})
    e = exam(lesson(p), [q])
    {:ok, share, token} = ExamShares.create(p.id, e.id, "fill")
    {:ok, view, _} = live(conn, "/partage/#{token}")
    image_path = "/partage/#{token}/images/#{image["id"]}"
    audio_path = "/partage/#{token}/audio/#{audio["id"]}"
    assert has_element?(view, "img[src='#{image_path}']")
    assert has_element?(view, "audio[src='#{audio_path}']")
    assert get(conn, image_path).status == 200
    assert get(conn, audio_path).status == 200
    assert get(conn, "/partage/#{token}/images/#{Ecto.UUID.generate()}").status == 404
    assert get(conn, "/partage/#{token}/audio/#{image["id"]}").status == 404
    Repo.update!(Ecto.Changeset.change(share, expires_at: DateTime.add(DateTime.utc_now(), -1)))
    assert get(conn, image_path).status == 404
    assert get(conn, audio_path).status == 404
  end
end

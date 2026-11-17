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

  test "owner can list shares and open a completed visitor correction", %{
    conn: conn,
    profile: p,
    exam: exam
  } do
    {:ok, share, token} = ExamShares.create(p.id, exam.id, "fill")
    {:ok, _, attempt} = ExamShares.open(token, "owner-list-test")

    {:ok, _} =
      Exams.submit({:shared, token, "owner-list-test"}, attempt.id, %{"q1" => "quart"},
        sync: true
      )

    {:ok, view, _} = live(conn, "/alice/parametres/partages")
    assert has_element?(view, ".page-shell[data-child-theme] #shared-evaluations-page.app")
    assert has_element?(view, "#shared-evaluations-title-breadcrumb a[href='/alice/parametres']")
    assert has_element?(view, "#shared-evaluations .shared-evaluation .shared-attempt-label")
    assert has_element?(view, "#shared-evaluations a.button.secondary")
    assert has_element?(view, "a[href='/alice/parametres/partages/#{attempt.id}']")
    Repo.update!(Ecto.Changeset.change(share, expires_at: DateTime.add(DateTime.utc_now(), -60)))
    {:ok, correction, _} = live(conn, "/alice/parametres/partages/#{attempt.id}")
    assert has_element?(correction, "#exam-title")
  end

  test "parents see all children's shares and can open and revoke another child's share", %{
    conn: conn,
    profile: alice,
    exam: alice_exam
  } do
    {:ok, alice_share, _} = ExamShares.create(alice.id, alice_exam.id, "fill")
    marius = profile("Marius")
    marius_exam = exam(lesson(marius, "anglais"))
    {:ok, marius_share, token} = ExamShares.create(marius.id, marius_exam.id, "fill")
    {:ok, _, attempt} = ExamShares.open(token, "all-children")

    {:ok, _} =
      Exams.submit({:shared, token, "all-children"}, attempt.id, %{"q1" => "quart"}, sync: true)

    {:ok, view, _} = live(conn, "/alice/parametres/partages")
    assert has_element?(view, "#shares-#{alice_share.id}")
    assert has_element?(view, "#shares-#{marius_share.id}")
    assert has_element?(view, "#shared-evaluation-subject-#{marius_share.id}", "Anglais")
    assert has_element?(view, "a[href='/marius/parametres/partages/#{attempt.id}']")

    {:ok, correction, _} = live(conn, "/marius/parametres/partages/#{attempt.id}")
    assert has_element?(correction, "#exam-title")

    view |> element("#delete-share-#{marius_share.id}") |> render_click()
    assert_redirect(view, "/alice/parametres/partages")
    assert {:error, :unavailable} = ExamShares.fetch(token)
    assert Repo.get!(Study.Exam, marius_exam.id)
  end

  @tag account: "child-1"
  test "children cannot access the shared evaluation settings", %{conn: conn} do
    assert conn |> get("/alice/parametres/partages") |> response(404)
  end

  test "shared copy badges distinguish blank, started and corrected answers", %{
    conn: conn,
    profile: p,
    exam: exam
  } do
    {:ok, _, token} = ExamShares.create(p.id, exam.id, "fill")
    {:ok, _, blank} = ExamShares.open(token, "blank-badge")
    Repo.update!(Ecto.Changeset.change(blank, answers: %{"q1" => "   "}))
    {:ok, _, started} = ExamShares.open(token, "started-badge")
    Repo.update!(Ecto.Changeset.change(started, answers: %{"q1" => "une réponse"}))
    {:ok, _, corrected} = ExamShares.open(token, "corrected-badge")
    Repo.update!(Ecto.Changeset.change(corrected, status: "completed", score: 14.25))
    {:ok, view, _} = live(conn, "/alice/parametres/partages")

    assert has_element?(
             view,
             "#shared-attempt-status-#{blank.id}[data-status='not_started']",
             "Non commencée"
           )

    assert has_element?(
             view,
             "#shared-attempt-status-#{started.id}[data-status='in_progress']",
             "En cours"
           )

    assert has_element?(
             view,
             "#shared-attempt-status-#{corrected.id}[data-status='completed']",
             "14,25/20"
           )
  end

  test "correction shares stay accessible but are hidden from the shared evaluation list", %{
    conn: conn,
    profile: p,
    exam: exam
  } do
    {:ok, _} = Exams.submit(p.id, exam.id, %{"q1" => "quart"}, sync: true)
    {:ok, correction_share, token} = ExamShares.create(p.id, exam.id, "correction")

    {:ok, view, _} = live(conn, "/alice/parametres/partages")
    assert has_element?(view, "#shared-evaluations-empty")
    refute has_element?(view, "#shares-#{correction_share.id}")

    {:ok, fill_share, _} = ExamShares.create(p.id, exam.id, "fill")
    {:ok, view, _} = live(conn, "/alice/parametres/partages")
    refute has_element?(view, "#shared-evaluations-empty")
    refute has_element?(view, "#shares-#{correction_share.id}")
    assert has_element?(view, "#shares-#{fill_share.id}")

    {:ok, correction, _} = live(conn, "/partage/#{token}")
    assert has_element?(correction, "#exam-title")
  end

  test "shared copies use the copy row layout and score colors", %{
    conn: conn,
    profile: p,
    exam: exam
  } do
    {:ok, _, token} = ExamShares.create(p.id, exam.id, "fill")

    for {score, color, label} <- [
          {9.0, "score-low", "9/20"},
          {10.0, "score-average", "10/20"},
          {15.75, "score-average", "15,75/20"},
          {16.0, "score-good", "16/20"}
        ] do
      {:ok, _, attempt} = ExamShares.open(token, "score-#{score}")
      Repo.update!(Ecto.Changeset.change(attempt, status: "completed", score: score))
      {:ok, view, _} = live(conn, "/alice/parametres/partages")

      assert has_element?(
               view,
               ".shared-evaluation-attempts li #shared-attempt-status-#{attempt.id}.#{color}",
               label
             )

      assert has_element?(
               view,
               ".shared-evaluation-attempts li a[href='/alice/parametres/partages/#{attempt.id}'] .shared-attempt-link-detail"
             )
    end
  end

  test "deleting a share revokes public access and preserves the original and copies", %{
    conn: conn,
    profile: p,
    exam: exam
  } do
    {:ok, share, token} = ExamShares.create(p.id, exam.id, "fill")
    {:ok, _, attempt} = ExamShares.open(token, "retained-copy")
    {:ok, other, other_token} = ExamShares.create(p.id, exam.id, "fill")
    owner = profile("Marius")
    assert_raise Ecto.NoResultsError, fn -> ExamShares.revoke(owner.id, share.id) end
    {:ok, public, _} = live(conn, "/partage/#{token}")
    {:ok, view, _} = live(conn, "/alice/parametres/partages")
    view |> element("#delete-share-#{share.id}") |> render_click()
    assert_redirect(view, "/alice/parametres/partages")
    assert {:error, :unavailable} = ExamShares.fetch(token)
    assert {:ok, _} = ExamShares.fetch(other_token)
    assert Repo.get!(Study.Exam, exam.id)
    assert Repo.get!(Study.Exam, attempt.id)
    assert has_element?(public, "#share-unavailable")
    {:ok, refreshed, _} = live(conn, "/alice/parametres/partages")
    refute has_element?(refreshed, "#delete-share-#{share.id}")
    assert has_element?(refreshed, "#delete-share-#{other.id}")
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

  test "both share modes preserve the saved question type label", %{conn: conn, profile: p} do
    q =
      question("translation", "definition")
      |> Map.put("type_contract", %{"name" => "Traduction en {langue}"})

    control = exam(lesson(p, "anglais"), [q])

    control
    |> Ecto.Changeset.change(
      status: "completed",
      score: 20.0,
      corrections: %{"translation" => %{"points" => q["points"]}}
    )
    |> Repo.update!()

    for mode <- ["fill", "correction"] do
      {:ok, _, token} = ExamShares.create(p.id, control.id, mode)
      {:ok, view, _} = live(conn, "/partage/#{token}")

      assert has_element?(
               view,
               "#question-translation .question-type-label",
               "Traduction en anglais"
             )
    end
  end

  test "shared URLs expose descriptive previews in the initial HTML", %{profile: p} do
    control = exam(lesson(p, "anglais"))
    {:ok, _} = Exams.submit(p.id, control.id, %{"q1" => "quart"}, sync: true)

    for {mode, prefix} <- [{"fill", "Évaluation"}, {"correction", "Corrigé de l’évaluation"}] do
      {:ok, _, token} = ExamShares.create(p.id, control.id, mode)
      conn = get(build_conn(), "/partage/#{token}")
      html = conn |> html_response(200) |> LazyHTML.from_document()
      title = "#{prefix} d’anglais — La cellule"

      assert LazyHTML.text(LazyHTML.query(html, "title")) =~ title

      assert LazyHTML.attribute(LazyHTML.query(html, "meta[property='og:title']"), "content") ==
               [title <> " | Captain Homework"]

      [image] = LazyHTML.attribute(LazyHTML.query(html, "meta[property='og:image']"), "content")
      assert URI.parse(image).scheme in ["http", "https"]
      assert URI.parse(image).path == "/images/brand/share-preview.png"

      assert LazyHTML.attribute(LazyHTML.query(html, "meta[name='twitter:card']"), "content") ==
               ["summary_large_image"]

      {:ok, view, _} = live(conn)
      assert page_title(view) == title
    end
  end

  test "unavailable shares do not expose preview metadata" do
    conn = get(build_conn(), "/partage/#{ExamShares.token()}")
    html = conn |> html_response(200) |> LazyHTML.from_document()
    assert LazyHTML.attribute(LazyHTML.query(html, "meta[property='og:title']"), "content") == []
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
    assert has_element?(view, "#exam-title", "Évaluation de #{Study.subject!("svt").name}")
    assert has_element?(view, "#shared-exam-subject-icon.green .icon")
    assert has_element?(view, "#shared-exam-lesson.muted", "La cellule")
    {:ok, _, attempt} = ExamShares.open(token, visitor)

    render_click(view, "delete_exam", %{})
    render_click(view, "open_source", %{"id" => Ecto.UUID.generate()})
    render_click(view, "create_lesson", %{"lesson" => %{"title" => "Forbidden"}})
    assert Repo.get(Study.Exam, e.id)
    refute has_element?(view, "#source-modal")

    view |> form("#exam-answers", answers: %{"q1" => "quart"}) |> render_submit()
    assert has_element?(view, "#submit-confirm", "1 réponse sur 1")
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

defmodule CaptainHomeworkWeb.PronunciationLiveTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.{AudioFixture, Repo, Study, Uploads}
  alias CaptainHomework.Exams.RecordingAnswers

  test "classic and flashcard use the real recorder, persist audio and reload it", %{conn: conn} do
    for format <- ~w(classic flashcard) do
      l = lesson(profile(), "anglais")

      e =
        exam(l, [AudioFixture.question()])
        |> Ecto.Changeset.change(format: format)
        |> Repo.update!()

      {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
      assert has_element?(view, "#voice-q1[phx-hook=PronunciationRecorder]")
      refute has_element?(view, "[phx-hook=QuestionPreviewRecorder]")

      assert has_element?(view, "#question-q1 .reading-text", "The weather is lovely today.") or
               has_element?(view, "#flashcard-q1", "The weather is lovely today.")

      form_id = if format == "classic", do: "#exam-answers", else: "#flashcard-answer"
      name = CaptainHomeworkWeb.HomeworkLive.recording_upload_name(e, "q1")

      upload =
        file_input(view, form_id, name, [
          %{name: "voice.wav", content: AudioFixture.wav(), type: "audio/wav"}
        ])

      render_upload(upload, "voice.wav")
      e = Study.get_exam!(l.profile_id, e.id)
      assert %{"storage_key" => key} = e.answers["q1"]
      assert File.regular?(Uploads.path(key))
      assert has_element?(view, "#recording-playback-q1")
      {:ok, refreshed, _} = live(conn, "/alice/controles/#{e.id}")
      assert has_element?(refreshed, "#recording-playback-q1")
      response_conn = get(conn, "/alice/controles/#{e.id}/audio/#{e.answers["q1"]["id"]}")
      assert response(response_conn, 200) == File.read!(Uploads.path(key))

      assert_error_sent 404, fn ->
        get(conn, "/marius/controles/#{e.id}/audio/#{e.answers["q1"]["id"]}")
      end

      assert has_element?(refreshed, "#voice-q1 [data-record-label]", "Recommencer")
      assert has_element?(refreshed, "#voice-q1 [data-record] .icon")
      assert has_element?(refreshed, "#recording-answer-q1 > audio:first-child")
      refute has_element?(refreshed, "#remove-recording-q1")
      RecordingAnswers.delete_files(e)
    end
  end

  test "completed classic answers display playback without exposing storage metadata", %{
    conn: conn
  } do
    l = lesson(profile(), "anglais")
    e = exam(l, [AudioFixture.question()])
    path = Path.join(System.tmp_dir!(), Ecto.UUID.generate() <> ".wav")
    File.write!(path, AudioFixture.wav())
    on_exit(fn -> File.rm(path) end)
    {:ok, e} = RecordingAnswers.put(l.profile_id, e.id, "q1", path)

    correction = %{
      "fraction" => 1,
      "points" => 1,
      "feedback" => "Bonne prononciation.",
      "expected" => AudioFixture.question()["text"],
      "language_errors" => []
    }

    e
    |> Ecto.Changeset.change(status: "completed", score: 20.0, corrections: %{"q1" => correction})
    |> Repo.update!()

    {:ok, view, _} = live(conn, "/alice/controles/#{e.id}")
    assert has_element?(view, "#recording-playback-q1")
    refute has_element?(view, "#voice-q1")
    assert has_element?(view, "#student-answer-q1 .correction-heading", "Réponse de Alice")
    assert has_element?(view, "#student-answer-q1 #recording-playback-q1")
    refute has_element?(view, "#student-answer-q1 .answer-language-row")
    RecordingAnswers.delete_files(e)
  end

  test "shared recordings belong only to their visitor and disappear when the source is deleted" do
    l = lesson(profile(), "anglais")
    e = exam(l, [AudioFixture.question()])

    e =
      e
      |> Ecto.Changeset.change(
        status: "completed",
        score: 20.0,
        corrections: %{"q1" => %{"points" => 1}}
      )
      |> Repo.update!()

    {:ok, _, token} = CaptainHomework.ExamShares.create(l.profile_id, e.id, "fill")
    first_conn = build_conn() |> get("/partage/#{token}")
    {:ok, view, _} = live(first_conn)
    assert has_element?(view, "#voice-q1[phx-hook=PronunciationRecorder]")
    [attempt] = CaptainHomework.ExamShares.attempts_for_exam(e.id)

    upload =
      file_input(
        view,
        "#exam-answers",
        CaptainHomeworkWeb.HomeworkLive.recording_upload_name(attempt, "q1"),
        [%{name: "voice.wav", content: AudioFixture.wav(), type: "audio/wav"}]
      )

    render_upload(upload, "voice.wav")
    attempt = Repo.get!(Study.Exam, attempt.id)
    asset = attempt.answers["q1"]
    url = "/partage/#{token}/audio/#{asset["id"]}"

    assert response(get(recycle(first_conn), url), 200) ==
             File.read!(Uploads.path(asset["storage_key"]))

    assert response(get(build_conn(), url), 404)
    {:ok, _} = Study.delete_exam(l.profile_id, e.id)
    refute File.exists?(Uploads.path(asset["storage_key"]))
    assert response(get(recycle(first_conn), url), 404)
  end
end

defmodule CaptainHomeworkWeb.ListeningLiveTest do
  use CaptainHomeworkWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Exams, Repo, Study, Uploads}

  test "both modes play private audio without exposing the transcript and grade the written answer",
       %{conn: conn} do
    l = lesson(profile(), "anglais")
    source = page(l)
    {:ok, [q]} = CaptainHomework.ListeningAI.generate(l, [source], [], 1, "", [])
    old = Application.fetch_env!(:captain_homework, :ai_provider)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.ListeningAI)
    on_exit(fn -> Application.put_env(:captain_homework, :ai_provider, old) end)

    for {format, extension, content_type} <- [
          {"classic", ".wav", "audio/wav"},
          {"flashcard", ".mp3", "audio/mpeg"}
        ] do
      id = Ecto.UUID.generate()
      key = "question-#{id}#{extension}"
      File.mkdir_p!(Uploads.directory())
      File.write!(Uploads.path(key), "test-audio")
      on_exit(fn -> File.rm(Uploads.path(key)) end)

      control =
        exam(l, [
          Map.put(q, "audio", %{"id" => id, "storage_key" => key, "content_type" => content_type})
        ])
        |> Ecto.Changeset.change(format: format)
        |> Repo.update!()

      {:ok, view, _} = live(conn, "/alice/controles/#{control.id}")
      url = "/alice/controles/#{control.id}/audio/#{id}"
      assert has_element?(view, "#question-audio-q1[controls][src='#{url}']")
      refute has_element?(view, ".reading-text")
      refute has_element?(view, "[data-audio-script]")
      refute has_element?(view, "*", q["audio_script"]["text"])
      audio_conn = get(conn, url)
      assert response(audio_conn, 200) == "test-audio"
      assert [served_type] = get_resp_header(audio_conn, "content-type")
      assert String.starts_with?(served_type, content_type)
      assert response(get(conn, "/alice/controles/#{control.id}/audio/missing"), 404)
      assert_error_sent 404, fn -> get(conn, "/bob/controles/#{control.id}/audio/#{id}") end

      if format == "flashcard" do
        assert has_element?(view, "#flashcard-response")

        {:ok, graded} =
          Exams.Flashcards.submit(l.profile_id, control.id, "q1", "She goes to the park.",
            sync: true
          )

        assert graded.corrections["q1"]["expected"] == q["answer"]
      else
        assert has_element?(view, "#answer-q1")

        view
        |> form("#exam-answers", answers: %{"q1" => "She goes to the park."})
        |> render_change()

        assert Study.get_exam!(l.profile_id, control.id).answers["q1"] == "She goes to the park."
      end
    end
  end

  test "oral comprehension is selectable in both modes", %{conn: conn} do
    l = lesson(profile(), "anglais")
    page(l)
    {:ok, _} = CaptainHomework.QuestionDefinitions.seed!()

    type =
      Enum.find(CaptainHomework.QuestionDefinitions.list(), &(&1.name == "Compréhension orale"))

    {:ok, view, _} = live(conn, "/alice/lecons/#{l.id}/controle")
    assert has_element?(view, "#question-type-#{type.id}:not([disabled])")
  end
end

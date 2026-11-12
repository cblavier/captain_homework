defmodule CaptainHomework.PronunciationTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.{AI, AudioFixture, QuestionDefinitions, Repo, Study, Uploads}
  alias CaptainHomework.Exams.{Flashcards, RecordingAnswers}

  setup do
    path = Path.join(System.tmp_dir!(), Ecto.UUID.generate() <> ".wav")
    File.write!(path, AudioFixture.wav())
    on_exit(fn -> File.rm(path) end)
    %{path: path}
  end

  test "pronunciation is selectable and validates in both modes" do
    QuestionDefinitions.seed!()
    l = lesson(profile(), "anglais")
    course = page(l)

    definition =
      Enum.find(QuestionDefinitions.available("anglais"), &(&1.name == "Prononciation"))

    assert QuestionDefinitions.generation_supported?(definition)
    assert QuestionDefinitions.engine_format(definition) == "pronunciation"

    for mode <- ~w(classic flashcard),
        do: assert(QuestionDefinitions.mode_allowed?(definition, mode))

    q = Map.put(AudioFixture.question(), "source_page_ids", [course.id])
    assert AI.question_errors(q) == []
    assert {[validated], []} = Flashcards.validate_candidates([q], [course])
    assert validated["text"] == validated["answer"]
    assert AI.question_errors(%{q | "text" => ""}) != []
  end

  test "recordings replace an existing answer with a legacy timestamp", %{path: path} do
    l = lesson(profile(), "anglais")
    e = exam(l, [AudioFixture.question()])
    {:ok, e} = RecordingAnswers.put(l.profile_id, e.id, "q1", path)
    previous = e.answers["q1"]

    Repo.query!("UPDATE exams SET updated_at = ? WHERE id = ?", [
      "2026-11-12 18:55:15",
      e.id
    ])

    assert {:ok, updated} = RecordingAnswers.put(l.profile_id, e.id, "q1", path)
    assert updated.answers["q1"]["id"] != previous["id"]
    refute File.exists?(Uploads.path(previous["storage_key"]))
    assert File.regular?(Uploads.path(updated.answers["q1"]["storage_key"]))
    RecordingAnswers.delete_files(updated)
  end

  test "recordings are saved, cannot be forged, replaced and deleted", %{path: path} do
    l = lesson(profile(), "anglais")
    e = exam(l, [AudioFixture.question()])
    {:ok, e} = RecordingAnswers.put(l.profile_id, e.id, "q1", path)
    asset = e.answers["q1"]
    assert asset["content_type"] == "audio/wav"
    assert File.regular?(Uploads.path(asset["storage_key"]))
    assert Study.sanitize_answers(e, %{"q1" => %{"storage_key" => "forged"}})["q1"] == asset
    {:ok, e} = RecordingAnswers.put(l.profile_id, e.id, "q1", path)
    refute File.exists?(Uploads.path(asset["storage_key"]))

    assert_raise Ecto.NoResultsError, fn ->
      RecordingAnswers.put(profile("Marius").id, e.id, "q1", path)
    end

    current = e.answers["q1"]
    {:ok, e} = RecordingAnswers.remove(l.profile_id, e.id, "q1")
    assert e.answers["q1"] == ""
    refute File.exists?(Uploads.path(current["storage_key"]))
  end

  test "generation, answering and correction work in classic and flashcard", %{path: path} do
    old = Application.fetch_env!(:captain_homework, :ai_provider)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.PronunciationAI)
    on_exit(fn -> Application.put_env(:captain_homework, :ai_provider, old) end)
    l = lesson(profile(), "anglais")
    page(l)
    QuestionDefinitions.seed!()
    type = Enum.find(QuestionDefinitions.available("anglais"), &(&1.name == "Prononciation"))

    for format <- ~w(classic flashcard) do
      assert {:ok, e} =
               CaptainHomework.Exams.generate(l.profile_id, l.id, 1, "",
                 format: format,
                 question_types: [type.id]
               )

      assert e.status == "in_progress", inspect(e.generation_errors)
      assert [q] = e.questions
      assert q["type_contract"]["name"] == "Prononciation"
      {:ok, e} = RecordingAnswers.put(l.profile_id, e.id, q["id"], path)

      if format == "flashcard" do
        assert {:ok, e} = Flashcards.submit(l.profile_id, e.id, q["id"], "", sync: true)
        assert e.corrections[q["id"]]["fraction"] == 1
      else
        assert {:ok, e} = CaptainHomework.Exams.submit(l.profile_id, e.id, %{}, sync: true)
        assert e.status == "completed"
        assert e.score == 20
      end

      RecordingAnswers.delete_files(e)
    end
  end

  test "flashcard recordings are limited to the current uncorrected card", %{path: path} do
    l = lesson(profile(), "anglais")
    q = AudioFixture.question()

    e =
      exam(l, [q, Map.put(q, "id", "q2")])
      |> Ecto.Changeset.change(format: "flashcard")
      |> Repo.update!()

    assert {:error, _} = RecordingAnswers.put(l.profile_id, e.id, "q2", path)
    assert {:ok, e} = RecordingAnswers.put(l.profile_id, e.id, "q1", path)
    e |> Ecto.Changeset.change(corrections: %{"q1" => %{}}) |> Repo.update!()
    assert {:error, _} = RecordingAnswers.put(l.profile_id, e.id, "q1", path)
    RecordingAnswers.delete_files(e)
  end

  test "grading sends the actual voice to an audio model and fails on missing audio", %{
    path: path
  } do
    old_key = Application.get_env(:captain_homework, :openai_api_key)
    old_options = Application.get_env(:captain_homework, :openai_request_options, [])
    Application.put_env(:captain_homework, :openai_api_key, "test")
    Application.put_env(:captain_homework, :openai_request_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.put_env(:captain_homework, :openai_api_key, old_key)
      Application.put_env(:captain_homework, :openai_request_options, old_options)
    end)

    l = lesson(profile(), "anglais")
    e = exam(l, [AudioFixture.question()])
    {:ok, e} = RecordingAnswers.put(l.profile_id, e.id, "q1", path)

    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/chat/completions"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(body)
      assert body["modalities"] == ["text"]
      audio = body["messages"] |> List.last() |> Map.fetch!("content") |> List.last()
      assert audio["type"] == "input_audio"

      assert Base.decode64!(audio["input_audio"]["data"]) ==
               File.read!(Uploads.path(e.answers["q1"]["storage_key"]))

      Req.Test.json(conn, %{
        choices: [
          %{
            finish_reason: "stop",
            message: %{
              content:
                Jason.encode!(%{fraction: 0.75, feedback: "Travaille le son th dans weather."})
            }
          }
        ]
      })
    end)

    assert {:ok, %{"grades" => [%{"fraction" => 0.75, "language_errors" => []}]}} =
             AI.OpenAI.grade(e)

    RecordingAnswers.delete_files(e)
    assert {:error, _} = AI.OpenAI.grade(e)
  end
end

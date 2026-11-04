defmodule CaptainHomework.ListeningTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.{AI, Exams, QuestionDefinitions, Repo, Study, Uploads}
  alias CaptainHomework.Exams.{Listening, Illustrations}

  setup do
    keys = [
      :ai_provider,
      :openai_api_key,
      :openai_realtime_options,
      :openai_request_options
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:captain_homework, &1)})
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.ListeningAI)
    Application.put_env(:captain_homework, :openai_api_key, "test-key")

    agent = start_supervised!({Agent, fn -> :success end})

    server =
      start_supervised!(
        {Bandit,
         plug: {CaptainHomework.RealtimeStub, %{owner: self(), agent: agent}},
         port: 0,
         ip: {127, 0, 0, 1}}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    Application.put_env(:captain_homework, :openai_realtime_options,
      url: "ws://127.0.0.1:#{port}/v1/realtime",
      timeout: 2_000
    )

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:captain_homework, key, value)
        {key, :error} -> Application.delete_env(:captain_homework, key)
      end)
    end)

    l = lesson(profile(), "anglais")
    page(l)
    {:ok, _} = QuestionDefinitions.seed!()
    type = Enum.find(QuestionDefinitions.list(), &(&1.name == "Compréhension orale"))
    %{lesson: l, type: type, agent: agent}
  end

  test "classic and flashcard generation store audio, preserve correction and copy files independently",
       %{lesson: l, type: type} do
    assert QuestionDefinitions.generation_supported?(type)

    for format <- ["classic", "flashcard"] do
      {:ok, generated} =
        Exams.generate(l.profile_id, l.id, 1, "", format: format, question_types: [type.id])

      assert generated.status == "in_progress"
      assert [q] = generated.questions
      assert q["type"] == "listening"
      assert q["text"] == ""
      assert q["audio_script"]["speaker_gender"] == "female"

      assert <<"RIFF", _::binary-size(32), "data", _::little-32, _::binary>> =
               File.read!(Uploads.path(q["audio"]["storage_key"]))

      assert q["audio"]["content_type"] == "audio/wav"
      assert_receive {:realtime_request, request, _}
      assert get_in(request, ["response", "audio", "output", "voice"]) == "marin"
      copied = Illustrations.copy_retry(q)
      assert copied["audio"]["id"] != q["audio"]["id"]
      Listening.delete(copied)
      assert File.regular?(Uploads.path(q["audio"]["storage_key"]))
      completed = generated |> Ecto.Changeset.change(status: "completed") |> Repo.update!()
      {:ok, redo} = Exams.redo(l.profile_id, completed.id)
      assert hd(redo.questions)["audio"]["id"] != q["audio"]["id"]
      assert {:ok, _} = Study.delete_exam(l.profile_id, completed.id)
      refute File.exists?(Uploads.path(q["audio"]["storage_key"]))
      assert File.regular?(Uploads.path(hd(redo.questions)["audio"]["storage_key"]))
      Study.delete_exam(l.profile_id, redo.id)
    end
  end

  test "a failed synthesis leaves a resumable exam instead of a silent question", %{
    lesson: l,
    type: type,
    agent: agent
  } do
    Agent.update(agent, fn _ -> :quota end)
    {:ok, partial} = Exams.generate(l.profile_id, l.id, 1, "", question_types: [type.id])
    assert partial.status == "generation_partial"
    assert partial.questions == []
    assert Enum.any?(partial.generation_errors, &String.contains?(&1, "quota"))
    Agent.update(agent, fn _ -> :success end)
    {:ok, ready} = Exams.resume_generation(l.profile_id, partial.id)
    assert ready.status == "in_progress"
    assert length(ready.questions) == 1
    Study.delete_exam(l.profile_id, ready.id)
  end

  test "scripts must be complete and cannot be displayed or used by another format" do
    {:ok, [q]} = CaptainHomework.ListeningAI.generate(nil, [%{id: "p"}], [], 1, "", [])
    assert AI.question_errors(q) == []

    for bad <- [
          Map.delete(q, "audio_script"),
          put_in(q, ["audio_script", "text"], ""),
          put_in(q, ["audio_script", "speaker_gender"], "Emma"),
          Map.put(q, "text", "Transcript"),
          Map.put(q, "support_id", "shared"),
          Map.put(q, "type", "definition")
        ] do
      assert AI.question_errors(bad) != []
    end

    assert AI.Speech.voice(%{"speaker_gender" => "male"}) == "cedar"
    assert AI.Speech.voice(%{"speaker_gender" => "female"}) == "marin"
    assert AI.Speech.voice(%{"speaker_gender" => "neutral"}) == "alloy"
  end

  test "OpenAI flashcards carry the audio script through auditing and synthesis", %{
    lesson: l,
    type: type
  } do
    Application.put_env(:captain_homework, :ai_provider, AI.OpenAI)
    Application.put_env(:captain_homework, :openai_request_options, plug: {Req.Test, __MODULE__})
    source = hd(Study.get_lesson!(l.profile_id, l.id).pages)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      properties = request["text"]["format"]["schema"]["properties"]
      [%{"content" => [%{"text" => prompt}]}] = request["input"]

      result =
        if properties["questions"] do
          assert properties["questions"]["items"]["properties"]["audio_script"]
          assert prompt =~ "personnage qui PARLE"
          {:ok, questions} = CaptainHomework.ListeningAI.generate(l, [source], [], 1, "", [])
          %{"questions" => questions}
        else
          questions =
            prompt |> String.trim() |> String.split("\n") |> List.last() |> Jason.decode!()

          assert hd(questions)["audio_script"]["text"] =~ "Emma"

          %{
            "reviews" =>
              Enum.map(questions, fn q ->
                %{
                  "plan_id" => q["plan_id"],
                  "actual_effort" => "direct",
                  "actual_basis" => "document",
                  "answer_exposed" => false,
                  "exposure_source_id" => "",
                  "exposure_quote" => "",
                  "consistent" => true,
                  "reason" => "Compréhension d’un extrait entendu."
                }
              end)
          }
        end

      Req.Test.json(conn, %{
        "status" => "completed",
        "output" => [
          %{"content" => [%{"type" => "output_text", "text" => Jason.encode!(result)}]}
        ]
      })
    end)

    {:ok, generated} =
      Exams.generate(l.profile_id, l.id, 1, "", format: "flashcard", question_types: [type.id])

    assert generated.status == "in_progress"
    assert hd(generated.questions)["answer_basis"] == "document"
    assert hd(generated.questions)["audio"]
    Study.delete_exam(l.profile_id, generated.id)
  end

  test "classic plans accept oral supports and freeze their script during repairs", %{lesson: l} do
    source = hd(Study.get_lesson!(l.profile_id, l.id).pages)
    {:ok, [q]} = CaptainHomework.ListeningAI.generate(l, [source], [], 1, "", [])

    q =
      Map.merge(q, %{
        "plan_id" => "q1",
        "objective" => "Comprendre une activité hebdomadaire",
        "skill" => "interpret",
        "expected_elements" => ["the park"]
      })

    plan = %{"questions" => [q], "supports" => []}
    assert :ok = Exams.Plan.validate_complete(plan, 1, ["listening"], [source], [], ["q1"])
    assert AI.QuestionContract.frozen([q])["q1"]["audio_script"] == q["audio_script"]
  end
end

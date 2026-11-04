defmodule CaptainHomework.SpeechTest do
  use ExUnit.Case, async: false
  alias CaptainHomework.AI.Speech

  setup do
    keys = [:openai_api_key, :openai_speech_model, :openai_realtime_options]
    previous = Map.new(keys, &{&1, Application.fetch_env(:captain_homework, &1)})
    Application.put_env(:captain_homework, :openai_api_key, "test-only-key")
    Application.put_env(:captain_homework, :openai_speech_model, "gpt-realtime-2.1-mini")
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

    %{
      agent: agent,
      script: %{
        "text" => "Every Saturday, Emma goes to the park.",
        "language" => "en",
        "speaker_gender" => "female"
      }
    }
  end

  test "collects PCM into a valid WAV and closes the connection", %{script: script} do
    assert {:ok, audio} = Speech.synthesize(script)

    assert <<"RIFF", 4836::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16,
             24_000::little-32, 48_000::little-32, 2::little-16, 16::little-16, "data",
             4800::little-32, pcm::binary>> = audio

    assert pcm == :binary.copy(<<0, 1>>, 2400)
    assert_receive {:realtime_request, request, pid}
    response = request["response"]
    assert request["type"] == "response.create"
    assert response["conversation"] == "none"
    assert response["output_modalities"] == ["audio"]

    assert response["audio"]["output"] == %{
             "voice" => "marin",
             "format" => %{"type" => "audio/pcm", "rate" => 24000}
           }

    assert get_in(response, ["input", Access.at(0), "content", Access.at(0), "text"]) ==
             script["text"]

    assert_receive :realtime_pong
    assert_receive {:realtime_closed, ^pid}
  end

  test "rejects partial, mismatched, corrupt, oversized and unrelated output", %{
    agent: agent,
    script: script
  } do
    for mode <- [
          :incomplete,
          :empty,
          :invalid_base64,
          :oversize,
          :mismatch,
          :wrong_response,
          :api_error,
          :disconnect
        ] do
      Agent.update(agent, fn _ -> mode end)
      assert {:error, message} = Speech.synthesize(script)
      assert is_binary(message)
      assert_receive {:realtime_request, _, pid}
      assert_receive {:realtime_closed, ^pid}, 1_000
    end
  end

  test "deadline closes a silent session without retrying", %{agent: agent, script: script} do
    Agent.update(agent, fn _ -> :timeout end)
    options = Application.fetch_env!(:captain_homework, :openai_realtime_options)

    Application.put_env(
      :captain_homework,
      :openai_realtime_options,
      Keyword.put(options, :timeout, 100)
    )

    assert {:error, message} = Speech.synthesize(script)
    assert message =~ "trop de temps"
    assert_receive {:realtime_request, _, pid}
    assert_receive {:realtime_closed, ^pid}
    refute_receive {:realtime_request, _, _}, 0
  end

  test "refuses a retired model and missing credentials before opening a connection", %{
    script: script
  } do
    Application.put_env(:captain_homework, :openai_speech_model, "tts-1")
    assert {:error, message} = Speech.synthesize(script)
    assert message =~ "Realtime"
    Application.delete_env(:captain_homework, :openai_api_key)
    assert {:error, message} = Speech.synthesize(script)
    assert message =~ "configurée"
    refute_receive {:realtime_request, _, _}, 0
  end
end

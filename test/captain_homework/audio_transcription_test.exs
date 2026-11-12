defmodule CaptainHomework.AudioTranscriptionTest do
  use ExUnit.Case, async: false
  alias CaptainHomework.AI.OpenAI

  setup do
    old_key = Application.get_env(:captain_homework, :openai_api_key)
    old_options = Application.get_env(:captain_homework, :openai_request_options, [])
    Application.put_env(:captain_homework, :openai_api_key, "test-key")
    Application.put_env(:captain_homework, :openai_request_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      Application.put_env(:captain_homework, :openai_api_key, old_key)
      Application.put_env(:captain_homework, :openai_request_options, old_options)
    end)

    :ok
  end

  test "audio is sent as a transcription file and returns unchanged text" do
    Req.Test.stub(__MODULE__, fn conn ->
      assert conn.request_path == "/v1/audio/transcriptions"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert body =~ "audio.mp3"
      assert body =~ "gpt-transcribe"
      assert body =~ "test-audio-bytes"
      Req.Test.json(conn, %{text: "Hello, je m’appelle Alice."})
    end)

    assert {:ok, "Hello, je m’appelle Alice."} =
             OpenAI.transcribe("test-audio-bytes", "audio/mpeg")
  end

  test "provider errors are actionable and do not expose response bodies" do
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 429, "sensitive details") end)
    assert {:error, error} = OpenAI.transcribe("audio", "audio/mpeg")
    assert error =~ "quota"
    refute error =~ "sensitive"
  end
end

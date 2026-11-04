defmodule CaptainHomework.RealtimeStubSocket do
  @behaviour WebSock
  def init(options), do: {:ok, options}

  def handle_in({data, [opcode: :text]}, state) do
    request = Jason.decode!(data)
    send(state.owner, {:realtime_request, request, self()})
    text = get_in(request, ["response", "input", Access.at(0), "content", Access.at(0), "text"])
    mode = state.mode

    pcm =
      if mode == :oversize,
        do: :binary.copy(<<0, 0>>, 2_880_001),
        else: :binary.copy(<<0, 1>>, 2400)

    transcript = if mode == :mismatch, do: "A different text.", else: text
    delta = if mode == :invalid_base64, do: "not base64!", else: Base.encode64(pcm)

    events = [
      %{"type" => "session.created", "session" => %{}},
      %{"type" => "response.created", "response" => %{"id" => "r1"}},
      %{"type" => "response.output_audio.delta", "response_id" => "r1", "delta" => delta},
      %{
        "type" => "response.done",
        "response" => %{
          "id" => "r1",
          "status" => if(mode == :incomplete, do: "incomplete", else: "completed"),
          "output" => [%{"content" => [%{"type" => "output_audio", "transcript" => transcript}]}]
        }
      }
    ]

    events =
      case mode do
        :empty -> Enum.reject(events, &(&1["type"] == "response.output_audio.delta"))
        :wrong_response -> List.update_at(events, 2, &Map.put(&1, "response_id", "other"))
        :api_error -> [%{"type" => "error", "error" => %{"code" => "insufficient_quota"}}]
        _ -> events
      end

    case mode do
      :timeout -> {:ok, state}
      :disconnect -> {:stop, :normal, state}
      _ -> {:push, [{:ping, "alive"} | Enum.map(events, &{:text, Jason.encode!(&1)})], state}
    end
  end

  def handle_control({"alive", [opcode: :pong]}, state) do
    send(state.owner, :realtime_pong)
    {:ok, state}
  end

  def handle_control(_, state), do: {:ok, state}

  def handle_info(_, state), do: {:ok, state}

  def terminate(_, state) do
    send(state.owner, {:realtime_closed, self()})
    :ok
  end
end

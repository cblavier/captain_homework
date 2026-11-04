defmodule CaptainHomework.AI.Realtime.Socket do
  @moduledoc "One bounded WebSocket exchange; sockets always close, with no automatic retry."
  alias Mint.{HTTP, WebSocket}
  @max_wire_bytes 16_000_000

  def run(url, headers, event, reducer, state, opts \\ []) do
    uri = URI.parse(url)
    secure? = uri.scheme == "wss"
    timeout = Keyword.get(opts, :timeout, 120_000)
    deadline = System.monotonic_time(:millisecond) + timeout
    path = (uri.path || "/") <> if(uri.query, do: "?" <> uri.query, else: "")

    with {:ok, conn} <-
           HTTP.connect(
             if(secure?, do: :https, else: :http),
             uri.host,
             uri.port || if(secure?, do: 443, else: 80),
             protocols: [:http1],
             mode: :passive,
             transport_opts: [timeout: min(timeout, 10_000), send_timeout: 10_000]
           ) do
      try do
        with {:ok, conn, ref} <-
               WebSocket.upgrade(if(secure?, do: :wss, else: :ws), conn, path, headers) do
          exchange = %{
            conn: conn,
            ref: ref,
            ws: nil,
            status: nil,
            headers: [],
            deadline: deadline,
            bytes: 0,
            event: event,
            reducer: reducer,
            state: state
          }

          receive_next(exchange)
        else
          _ -> {:error, :connection}
        end
      after
        HTTP.close(conn)
      end
    else
      _ -> {:error, :connection}
    end
  end

  defp receive_next(exchange) do
    remaining = exchange.deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      {:error, :timeout}
    else
      case WebSocket.recv(exchange.conn, 0, min(remaining, 15_000)) do
        {:ok, conn, messages} ->
          case consume(messages, %{exchange | conn: conn}) do
            {:continue, exchange} -> receive_next(exchange)
            result -> result
          end

        {:error, _, :timeout, _} ->
          {:error, :timeout}

        {:error, _, %Mint.TransportError{reason: :timeout}, _} ->
          {:error, :timeout}

        _ ->
          {:error, :connection}
      end
    end
  end

  defp consume([], exchange), do: {:continue, exchange}

  defp consume([message | rest], exchange) do
    case handle(message, exchange) do
      {:continue, exchange} -> consume(rest, exchange)
      result -> result
    end
  end

  defp handle({:status, ref, status}, %{ref: ref} = exchange),
    do: {:continue, %{exchange | status: status}}

  defp handle({:headers, ref, headers}, %{ref: ref} = exchange),
    do: {:continue, %{exchange | headers: exchange.headers ++ headers}}

  defp handle({:done, ref}, %{ref: ref, status: 101} = exchange) do
    with {:ok, conn, ws} <-
           WebSocket.new(exchange.conn, ref, 101, exchange.headers, mode: :passive),
         {:ok, exchange} <-
           send_frame(%{exchange | conn: conn, ws: ws}, {:text, Jason.encode!(exchange.event)}) do
      {:continue, exchange}
    else
      _ -> {:error, :protocol}
    end
  end

  defp handle({:done, _}, exchange), do: {:error, {:http, exchange.status}}

  defp handle({:data, _, _}, %{ws: nil, status: status}) when status != 101,
    do: {:error, {:http, status}}

  defp handle({:data, ref, data}, %{ref: ref} = exchange) do
    bytes = exchange.bytes + byte_size(data)

    if bytes > @max_wire_bytes do
      {:error, :too_large}
    else
      case WebSocket.decode(exchange.ws, data) do
        {:ok, ws, frames} -> consume_frames(frames, %{exchange | ws: ws, bytes: bytes})
        _ -> {:error, :protocol}
      end
    end
  end

  defp handle(_, _), do: {:error, :protocol}

  defp consume_frames([], exchange), do: {:continue, exchange}

  defp consume_frames([{:text, text} | rest], exchange) do
    with {:ok, event} when is_map(event) <- Jason.decode(text) do
      case exchange.reducer.(event, exchange.state) do
        {:continue, state} ->
          consume_frames(rest, %{exchange | state: state})

        {:ok, result} ->
          send_frame(exchange, :close)
          {:ok, result}

        {:error, reason} ->
          {:error, reason}
      end
    else
      _ -> {:error, :protocol}
    end
  end

  defp consume_frames([{:ping, data} | rest], exchange) do
    case send_frame(exchange, {:pong, data}) do
      {:ok, exchange} -> consume_frames(rest, exchange)
      _ -> {:error, :connection}
    end
  end

  defp consume_frames([{:pong, _} | rest], exchange), do: consume_frames(rest, exchange)
  defp consume_frames(_, _), do: {:error, :connection}

  defp send_frame(exchange, frame) do
    with {:ok, ws, data} <- WebSocket.encode(exchange.ws, frame),
         {:ok, conn} <- WebSocket.stream_request_body(exchange.conn, exchange.ref, data) do
      {:ok, %{exchange | conn: conn, ws: ws}}
    end
  end
end

defmodule CaptainHomework.RealtimeStub do
  @behaviour Plug
  def init(options), do: options

  def call(conn, options) do
    mode = Agent.get(options.agent, & &1)

    if mode == :quota do
      Plug.Conn.send_resp(conn, 429, "quota")
    else
      conn
      |> WebSockAdapter.upgrade(
        CaptainHomework.RealtimeStubSocket,
        Map.put(options, :mode, mode),
        []
      )
      |> Plug.Conn.halt()
    end
  end
end

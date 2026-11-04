defmodule CaptainHomework.AI.WorkLimiter do
  @moduledoc "Bounds concurrent exercise construction requests across all exams."
  use GenServer

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)

  def run(fun, server \\ __MODULE__) do
    ensure_started(server)
    lease = GenServer.call(server, :checkout, :infinity)

    try do
      fun.()
    after
      GenServer.cast(server, {:release, lease})
    end
  end

  # The development server can load this module without restarting Application.
  # Attach the missing child to its normal supervisor, never to a request process.
  defp ensure_started(__MODULE__) do
    if is_nil(Process.whereis(__MODULE__)) do
      Supervisor.start_child(
        CaptainHomework.Supervisor,
        {__MODULE__, limit: Application.get_env(:captain_homework, :exercise_concurrency, 3)}
      )
    end

    :ok
  end

  defp ensure_started(_server), do: :ok

  @impl true
  def init(opts) do
    limit = Keyword.get(opts, :limit, 3)
    {:ok, %{limit: max(limit, 1), active: %{}, waiting: :queue.new()}}
  end

  @impl true
  def handle_call(:checkout, {pid, _} = from, state) do
    ref = Process.monitor(pid)
    state = %{state | waiting: :queue.in({from, ref}, state.waiting)}
    {:noreply, grant(state)}
  end

  @impl true
  def handle_cast({:release, ref}, state) do
    Process.demonitor(ref, [:flush])
    {:noreply, grant(%{state | active: Map.delete(state.active, ref)})}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, state) do
    waiting =
      state.waiting
      |> :queue.to_list()
      |> Enum.reject(&(elem(&1, 1) == ref))
      |> :queue.from_list()

    {:noreply, grant(%{state | active: Map.delete(state.active, ref), waiting: waiting})}
  end

  defp grant(%{active: active, limit: limit} = state) when map_size(active) >= limit, do: state

  defp grant(state) do
    case :queue.out(state.waiting) do
      {{:value, {from, ref}}, waiting} ->
        GenServer.reply(from, ref)
        grant(%{state | waiting: waiting, active: Map.put(state.active, ref, true)})

      {:empty, _} ->
        state
    end
  end
end

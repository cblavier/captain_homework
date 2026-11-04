defmodule CaptainHomework.AI.WorkLimiterTest do
  use ExUnit.Case, async: true

  alias CaptainHomework.AI.WorkLimiter

  setup do
    supervisor = start_supervised!({Task.Supervisor, []})
    %{supervisor: supervisor}
  end

  defp limiter(limit) do
    name = {:global, {__MODULE__, make_ref()}}
    server = start_supervised!({WorkLimiter, name: name, limit: limit})
    :erlang.trace(server, true, [:receive])
    server
  end

  defp worker(supervisor, server, fun \\ nil) do
    owner = self()

    {:ok, pid} =
      Task.Supervisor.start_child(supervisor, fn ->
        WorkLimiter.run(
          fn ->
            send(owner, {:entered, self()})

            if fun do
              fun.()
            else
              receive do
                :finish -> :ok
              end
            end
          end,
          server
        )
      end)

    {pid, Process.monitor(pid)}
  end

  defp checked_out(server, pid) do
    assert_receive {:trace, ^server, :receive, {:"$gen_call", {^pid, _}, :checkout}}, 1_000
    # Receiving the trace proves the checkout reached the server; this barrier
    # ensures it has also finished processing it before checking queue behavior.
    _ = :sys.get_state(server)
  end

  defp finish({pid, ref}) do
    send(pid, :finish)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
  end

  test "the limit applies to workers from different callers until their work finishes", %{
    supervisor: supervisor
  } do
    server = limiter(2)
    [first, second, third, fourth] = for _ <- 1..4, do: worker(supervisor, server)

    for {pid, _} <- [first, second, third, fourth], do: checked_out(server, pid)

    assert_receive {:entered, first_pid}, 1_000
    assert_receive {:entered, second_pid}, 1_000
    refute_received {:entered, _}

    workers = [first, second, third, fourth]
    active = Enum.filter(workers, &(elem(&1, 0) in [first_pid, second_pid]))
    waiting = Enum.reject(workers, &(elem(&1, 0) in [first_pid, second_pid]))

    finish(hd(active))
    assert_receive {:entered, third_pid}, 1_000
    assert third_pid in Enum.map(waiting, &elem(&1, 0))
    _ = :sys.get_state(server)
    refute_received {:entered, _}

    finish(List.last(active))
    assert_receive {:entered, fourth_pid}, 1_000
    assert fourth_pid in Enum.map(waiting, &elem(&1, 0))
    refute third_pid == fourth_pid

    Enum.each(waiting, &finish/1)
  end

  test "a queued worker that dies cannot consume the next available permit", %{
    supervisor: supervisor
  } do
    server = limiter(1)
    first = worker(supervisor, server)
    {first_pid, _} = first
    assert_receive {:entered, ^first_pid}, 1_000

    {cancelled_pid, cancelled_ref} = worker(supervisor, server)
    checked_out(server, cancelled_pid)
    next = worker(supervisor, server)
    {next_pid, _} = next
    checked_out(server, next_pid)
    refute_received {:entered, _}

    Process.exit(cancelled_pid, :kill)
    assert_receive {:DOWN, ^cancelled_ref, :process, ^cancelled_pid, :killed}, 1_000
    finish(first)

    assert_receive {:entered, ^next_pid}, 1_000
    refute_received {:entered, ^cancelled_pid}
    finish(next)
  end

  test "a killed active worker releases its permit through its process monitor", %{
    supervisor: supervisor
  } do
    server = limiter(1)
    {first_pid, first_ref} = worker(supervisor, server)
    assert_receive {:entered, ^first_pid}, 1_000
    next = worker(supervisor, server)
    {next_pid, _} = next
    checked_out(server, next_pid)

    Process.exit(first_pid, :kill)
    assert_receive {:DOWN, ^first_ref, :process, ^first_pid, :killed}, 1_000
    assert_receive {:entered, ^next_pid}, 1_000
    finish(next)
  end

  test "an exception releases the permit even while its caller remains running", %{
    supervisor: supervisor
  } do
    server = limiter(1)
    owner = self()

    {:ok, caller} =
      Task.Supervisor.start_child(supervisor, fn ->
        try do
          WorkLimiter.run(
            fn ->
              send(owner, {:entered, self()})

              receive do
                :raise -> raise "construction failed"
              end
            end,
            server
          )
        rescue
          RuntimeError -> send(owner, {:rescued, self()})
        end

        receive do
          :finish -> :ok
        end
      end)

    caller_ref = Process.monitor(caller)
    assert_receive {:entered, ^caller}, 1_000
    next = worker(supervisor, server)
    {next_pid, _} = next
    checked_out(server, next_pid)

    send(caller, :raise)
    assert_receive {:rescued, ^caller}, 1_000
    assert_receive {:entered, ^next_pid}, 1_000
    refute_received {:DOWN, ^caller_ref, :process, ^caller, _}

    finish(next)
    finish({caller, caller_ref})
  end
end

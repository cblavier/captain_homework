defmodule CaptainHomework.Exams.GenerationJobs do
  use GenServer
  alias CaptainHomework.Exams.Generation

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def start(exam, lesson, pages, examples, opts) do
    GenServer.call(__MODULE__, {:start, exam, lesson, pages, examples, opts})
  end

  def running?(exam) do
    GenServer.call(__MODULE__, {:running, exam.id, exam.generation_started_at})
  catch
    :exit, _ -> false
  end

  @impl true
  def init(_), do: {:ok, %{}}

  @impl true
  def handle_call({:running, id, started}, _, jobs) do
    running =
      Enum.any?(jobs, fn {_, job} ->
        job.exam.id == id and job.exam.generation_started_at == started
      end)

    {:reply, running, jobs}
  end

  @impl true
  def handle_call({:start, exam, lesson, pages, examples, opts}, _, jobs) do
    if Enum.any?(jobs, fn {_, job} -> job.exam.id == exam.id end) do
      {:reply, {:error, "La génération est déjà en cours."}, jobs}
    else
      task =
        Task.Supervisor.async_nolink(CaptainHomework.Exams.GenerationTasks, fn ->
          Generation.run(exam, lesson, pages, examples, opts)
        end)

      timer =
        Process.send_after(
          self(),
          {:timeout, task.ref},
          Application.get_env(:captain_homework, :generation_timeout, 600_000)
        )

      {:reply, {:ok, exam},
       Map.put(jobs, task.ref, %{
         task: task,
         timer: timer,
         exam: exam,
         started_at: System.monotonic_time(:millisecond)
       })}
    end
  end

  @impl true
  def handle_info({ref, {:ok, %{status: status}}}, jobs)
      when is_reference(ref) and status != "generating" do
    Process.demonitor(ref, [:flush])
    finish_job(jobs, ref, nil)
  end

  def handle_info({ref, _result}, jobs) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    finish_job(
      jobs,
      ref,
      "La génération a été interrompue. Les questions prêtes sont conservées ; reprends les questions manquantes."
    )
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, jobs) do
    finish_job(
      jobs,
      ref,
      "La génération a été interrompue. Les questions prêtes sont conservées ; reprends les questions manquantes."
    )
  end

  def handle_info({:timeout, ref}, jobs) do
    if job = jobs[ref] do
      Generation.interrupt(
        job.exam,
        "La génération a dépassé le délai maximal. Les questions prêtes sont conservées ; reprends les questions manquantes.",
        elapsed_ms(job)
      )

      Process.exit(job.task.pid, :kill)
      Process.cancel_timer(job.timer)
    end

    {:noreply, Map.delete(jobs, ref)}
  end

  defp elapsed_ms(%{started_at: started}), do: System.monotonic_time(:millisecond) - started
  defp elapsed_ms(_), do: nil

  defp finish_job(jobs, ref, reason) do
    case Map.pop(jobs, ref) do
      {nil, jobs} ->
        {:noreply, jobs}

      {job, jobs} ->
        Process.cancel_timer(job.timer)

        if reason,
          do:
            Generation.interrupt(
              job.exam,
              reason,
              elapsed_ms(job)
            )

        {:noreply, jobs}
    end
  end
end

defmodule CaptainHomework.Exams.GenerationSupervisor do
  use Supervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_) do
    Supervisor.init(
      [
        {Task.Supervisor, name: CaptainHomework.Exams.GenerationTasks},
        CaptainHomework.Exams.GenerationJobs
      ],
      strategy: :one_for_all
    )
  end
end

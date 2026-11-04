defmodule CaptainHomework.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      CaptainHomeworkWeb.Telemetry,
      CaptainHomework.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:captain_homework, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:captain_homework, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: CaptainHomework.PubSub},
      {Task.Supervisor, name: CaptainHomework.Tasks},
      {CaptainHomework.AI.WorkLimiter,
       limit: Application.get_env(:captain_homework, :exercise_concurrency, 3)},
      CaptainHomework.Exams.GenerationSupervisor,
      # Start a worker by calling: CaptainHomework.Worker.start_link(arg)
      # {CaptainHomework.Worker, arg},
      # Start to serve requests, typically the last entry
      CaptainHomeworkWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: CaptainHomework.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    CaptainHomeworkWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end

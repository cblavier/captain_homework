defmodule CaptainHomework.Resources.MediaCommand do
  @moduledoc false

  def run(name, args, timeout \\ 600_000) do
    case System.find_executable(name) do
      nil ->
        {:error, "Le traitement audio nécessite #{name} sur le serveur."}

      executable ->
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: args
          ])

        collect(port, "", System.monotonic_time(:millisecond) + timeout)
    end
  end

  defp collect(port, output, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(
          port,
          binary_part(output <> data, 0, min(byte_size(output <> data), 32_000)),
          deadline
        )

      {^port, {:exit_status, 0}} ->
        {:ok, output}

      {^port, {:exit_status, _}} ->
        {:error,
         "Le média est inaccessible, illisible ou ne contient pas de piste audio. Pour YouTube, vérifie que la vidéo est publique et disponible."}
    after
      remaining ->
        case Port.info(port, :os_pid) do
          {:os_pid, pid} -> System.cmd("kill", ["-TERM", to_string(pid)], stderr_to_stdout: true)
          _ -> :ok
        end

        if Port.info(port), do: Port.close(port)
        {:error, "Le traitement audio a pris trop de temps. Réessaie avec un extrait plus court."}
    end
  end
end

defmodule CaptainHomework.BlockingGenerationAI do
  @behaviour CaptainHomework.AI
  def transcribe(_, _), do: {:error, "Unused"}
  def grade(_), do: {:error, "Unused"}

  def generate(_, _, _, _, _, kept) do
    send(
      Application.fetch_env!(:captain_homework, :generation_test_pid),
      {:generation_waiting, self(), kept}
    )

    receive do
      {:generation_reply, result} -> result
    end
  end
end

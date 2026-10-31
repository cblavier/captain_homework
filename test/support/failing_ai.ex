defmodule CaptainHomework.FailingAI do
  @behaviour CaptainHomework.AI
  def transcribe(_, _), do: {:error, "Service indisponible"}
  def generate(_, _, _, _, _, _), do: {:error, "Service indisponible"}
  def grade(_), do: {:error, "Service indisponible"}
end

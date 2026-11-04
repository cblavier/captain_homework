defmodule CaptainHomework.PhotoAI do
  @behaviour CaptainHomework.AI
  def transcribe(_, _), do: {:error, "unused"}
  def grade(_), do: {:error, "unused"}

  def generate(_, _, _, count, _, _) do
    {:ok,
     for(
       n <- 1..count,
       do:
         CaptainHomework.Fixtures.question("photo#{n}", "photo")
         |> Map.put("prompt", "Trace le triangle #{n}.")
     )}
  end
end

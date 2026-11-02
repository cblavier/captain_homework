defmodule CaptainHomework.SequenceAI do
  @behaviour CaptainHomework.AI
  def transcribe(_, _), do: {:error, "Not used"}
  def grade(_), do: {:error, "Not used"}

  def generate_flashcards(lesson, pages, count, instructions, kept, _types),
    do: generate(lesson, pages, [], count, instructions, kept)

  def generate(_, _, _, count, instructions, kept) do
    Agent.get_and_update(__MODULE__, fn state ->
      [response | rest] = state.responses

      {response,
       %{
         state
         | responses: rest,
           calls: state.calls ++ [%{count: count, instructions: instructions, kept: kept}]
       }}
    end)
  end
end

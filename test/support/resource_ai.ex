defmodule CaptainHomework.ResourceAI do
  @behaviour CaptainHomework.AI
  def transcribe(_, _), do: {:ok, "Texte du document"}

  def generate(_lesson, pages, examples, count, _instructions, retries) do
    send(
      Application.fetch_env!(:captain_homework, :resource_test_pid),
      {:resource_generation, pages, retries}
    )

    send(
      Application.fetch_env!(:captain_homework, :resource_test_pid),
      {:style_examples, examples}
    )

    ids = Application.get_env(:captain_homework, :resource_test_image_ids, [])

    {:ok,
     Enum.map(1..count, fn index ->
       CaptainHomework.Fixtures.question("q#{index}")
       |> Map.put("prompt", "Exercice du document #{index}")
       |> Map.put("image_ids", ids)
     end)}
  end

  def grade(_), do: {:ok, []}
end

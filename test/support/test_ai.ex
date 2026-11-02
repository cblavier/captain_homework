defmodule CaptainHomework.TestAI do
  @behaviour CaptainHomework.AI
  def transcribe(_, _), do: {:ok, "Texte reconnu sur la photo."}

  def generate(_lesson, _pages, _examples, count, _instructions, _retries) do
    {:ok,
     Enum.map(1..count, fn index ->
       CaptainHomework.Fixtures.question("new#{index}")
       |> Map.delete("id")
       |> Map.delete("origin_id")
       |> Map.put("prompt", "Question nouvelle #{index}")
     end)}
  end

  def grade(exam) do
    grades =
      Enum.map(exam.questions, fn q ->
        fraction =
          case exam.answers[q["id"]] do
            "moitié" -> 0.5
            "quart" -> 0.25
            "trois quarts" -> 0.75
            "faux" -> 0
            _ -> 1
          end

        %{
          "id" => q["id"],
          "fraction" => fraction,
          "feedback" => "La membrane délimite la cellule."
        }
      end)

    {:ok,
     %{
       "grades" => grades,
       "appreciation" => "Des connaissances solides ; précise tes justifications."
     }}
  end
end

defmodule CaptainHomework.PronunciationAI do
  @behaviour CaptainHomework.AI
  def transcribe(_, _), do: {:error, :unused}
  def grade(exam), do: CaptainHomework.TestAI.grade(exam)

  def generate(_, pages, _, count, _, _) do
    {:ok,
     for index <- 1..count do
       CaptainHomework.AudioFixture.question()
       |> Map.merge(%{
         "id" => "q#{index}",
         "source_page_ids" => [hd(pages).id],
         "image_ids" => []
       })
     end}
  end

  def generate_flashcards(lesson, pages, count, instructions, kept, _types),
    do: generate(lesson, pages, [], count, instructions, kept)
end

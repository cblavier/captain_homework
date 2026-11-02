defmodule CaptainHomework.FlashcardAI do
  defdelegate grade(exam), to: CaptainHomework.TestAI

  def generate_flashcards(lesson, pages, count, _instructions, kept, types) do
    send(self(), {:flashcard_sources, lesson, pages, types})

    {:ok,
     Enum.map(1..count, fn index ->
       CaptainHomework.Fixtures.question("card#{length(kept) + index}", "definition")
       |> Map.merge(%{
         "prompt" => "Notion #{length(kept) + index}",
         "response_effort" => "direct",
         "answer_basis" => "knowledge",
         "source_page_ids" => [Enum.at(pages, rem(index - 1, length(pages))).id],
         "image_ids" => []
       })
     end)}
  end
end

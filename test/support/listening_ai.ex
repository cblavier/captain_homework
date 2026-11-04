defmodule CaptainHomework.ListeningAI do
  @behaviour CaptainHomework.AI
  def transcribe(_, _), do: {:error, :unused}
  def grade(exam), do: CaptainHomework.TestAI.grade(exam)
  def synthesize_speech(script), do: CaptainHomework.AI.OpenAI.synthesize_speech(script)

  def generate(_, pages, _, count, _, _) do
    {:ok,
     for index <- 1..count do
       CaptainHomework.Fixtures.question("q#{index}", "listening")
       |> Map.merge(%{
         "prompt" => "Listen. Where does Emma go on Saturday?",
         "audio_script" => %{
           "text" => "Hello, I am Emma. Every Saturday I go to the park with my brother.",
           "language" => "en",
           "speaker_gender" => "female"
         },
         "answer" => "She goes to the park.",
         "rubric" => "Identifie le parc, les formulations équivalentes sont acceptées.",
         "points" => 1,
         "image_ids" => [],
         "source_page_ids" => [hd(pages).id],
         "answer_basis" => "document",
         "response_effort" => "direct",
         "support_id" => ""
       })
     end}
  end

  def generate_flashcards(lesson, pages, count, instructions, kept, _types),
    do: generate(lesson, pages, [], count, instructions, kept)
end

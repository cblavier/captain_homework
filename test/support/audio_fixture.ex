defmodule CaptainHomework.AudioFixture do
  def wav do
    pcm = :binary.copy(<<0, 0>>, 8000)
    size = byte_size(pcm)

    <<"RIFF", size + 36::little-32, "WAVEfmt ", 16::little-32, 1::little-16, 1::little-16,
      16000::little-32, 32000::little-32, 2::little-16, 16::little-16, "data", size::little-32,
      pcm::binary>>
  end

  def question do
    CaptainHomework.Fixtures.question()
    |> Map.merge(%{
      "type" => "pronunciation",
      "prompt" => "Lis à voix haute le texte suivant.",
      "text" => "The weather is lovely today.",
      "answer" => "The weather is lovely today.",
      "rubric" => "Prononcer clairement les mots et les sons.",
      "points" => 1,
      "answer_basis" => "document",
      "response_effort" => "direct",
      "support_id" => ""
    })
  end
end

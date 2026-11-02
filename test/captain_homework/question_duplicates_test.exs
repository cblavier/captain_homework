defmodule CaptainHomework.QuestionDuplicatesTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.{AI, Exams, SequenceAI}

  setup do
    old = AI.provider()
    Application.put_env(:captain_homework, :ai_provider, SequenceAI)
    on_exit(fn -> Application.put_env(:captain_homework, :ai_provider, old) end)
    p = profile()
    l = lesson(p)
    source = page(l)
    %{profile: p, lesson: l, source: source}
  end

  defp sequence(responses) do
    start_supervised!(%{
      id: SequenceAI,
      start:
        {Agent, :start_link, [fn -> %{responses: responses, calls: []} end, [name: SequenceAI]]}
    })
  end

  defp translations(source_id) do
    words = [
      {"squelette", "skeleton"},
      {"bougie", "candle"},
      {"fantôme", "ghost"},
      {"sorcière", "witch"},
      {"citrouille", "pumpkin"}
    ]

    Enum.flat_map(["anglais", "français"], fn language ->
      Enum.map(words, fn {french, english} ->
        {text, answer} =
          if language == "anglais",
            do: {"Comment dit-on « #{french} » en anglais ?", english},
            else: {"Que veut dire « #{english} » en français ?", french}

        question("#{language}-#{english}", "definition")
        |> Map.merge(%{
          "prompt" =>
            if(language == "anglais",
              do: "Traduction vers l’anglais",
              else: "Traduction vers le français"
            ),
          "text" => text,
          "answer" => answer,
          "rubric" => "Réponse attendue : #{answer}.",
          "source_page_ids" => [source_id],
          "response_effort" => "direct",
          "answer_basis" => "knowledge",
          "support_id" => "",
          "image_ids" => []
        })
      end)
    end)
  end

  test "ten distinct translations sharing two headings are all accepted", %{
    profile: p,
    lesson: l,
    source: source
  } do
    questions = translations(source.id)
    sequence([{:ok, questions}])

    assert {:ok, generated} =
             Exams.generate(p.id, l.id, 10, "",
               format: "flashcard",
               question_types: ["definition"]
             )

    assert generated.status == "in_progress"
    assert generated.generation_errors == []
    assert Enum.map(generated.questions, & &1["text"]) == Enum.map(questions, & &1["text"])
    assert [%{count: 10}] = Agent.get(SequenceAI, & &1.calls)
  end

  test "an identical prompt and text is still rejected when its answer and rubric differ", %{
    profile: p,
    lesson: l,
    source: source
  } do
    [first, second | _] = translations(source.id)

    duplicate =
      first
      |> Map.merge(%{
        "id" => "duplicate",
        "prompt" => "  TRADUCTION VERS L’ANGLAIS  ",
        "text" => "  COMMENT DIT-ON « SQUELETTE » EN ANGLAIS ?  ",
        "answer" => "a skeleton",
        "rubric" => "Accepter aussi skeleton."
      })

    sequence([{:ok, [first, duplicate]}, {:ok, [second]}])

    assert {:ok, generated} =
             Exams.generate(p.id, l.id, 2, "",
               format: "flashcard",
               question_types: ["definition"]
             )

    assert generated.status == "in_progress"
    assert Enum.map(generated.questions, & &1["text"]) == [first["text"], second["text"]]
    assert [%{count: 2}, %{count: 1, instructions: feedback}] = Agent.get(SequenceAI, & &1.calls)
    assert feedback =~ "répète un énoncé"
  end

  test "resuming two retained translations accepts eight new words without replacing saved IDs",
       %{
         profile: p,
         lesson: l,
         source: source
       } do
    questions = translations(source.id)
    kept = [Enum.at(questions, 0), Enum.at(questions, 5)]
    missing = questions -- kept
    sequence([{:ok, kept}, {:error, "Interruption du service"}, {:ok, missing}])

    assert {:ok, partial} =
             Exams.generate(p.id, l.id, 10, "",
               format: "flashcard",
               question_types: ["definition"]
             )

    assert partial.status == "generation_partial"
    assert length(partial.questions) == 2
    saved_ids = Enum.map(partial.questions, & &1["id"])

    assert {:ok, complete} = Exams.resume_generation(p.id, partial.id)
    assert complete.status == "in_progress"
    assert length(complete.questions) == 10
    assert complete.generation_errors == []
    assert complete.id == partial.id
    assert Enum.map(Enum.take(complete.questions, 2), & &1["id"]) == saved_ids

    assert Enum.map(complete.questions, & &1["text"]) ==
             Enum.map(kept ++ missing, & &1["text"])

    assert [%{count: 10}, %{count: 8}, %{count: 8}] = Agent.get(SequenceAI, & &1.calls)
  end
end

defmodule CaptainHomework.FlashcardsTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Exams, Repo, Study}
  alias CaptainHomework.Exams.Flashcards

  setup do
    old = Application.fetch_env!(:captain_homework, :ai_provider)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.FlashcardAI)
    on_exit(fn -> Application.put_env(:captain_homework, :ai_provider, old) end)
    :ok
  end

  defp flash_exam(lesson, count \\ 2) do
    questions = Enum.map(1..count, &(question("q#{&1}", "definition") |> Map.put("points", 1)))
    exam(lesson, questions) |> Ecto.Changeset.change(format: "flashcard") |> Repo.update!()
  end

  test "generation uses every course page, ignores examples, pending resources and past controls" do
    p = profile()
    l = lesson(p)
    first = page(l)
    second = page(l)
    page(l) |> Ecto.Changeset.change(kind: "example", text: "") |> Repo.update!()
    Repo.insert!(%Study.Resource{lesson_id: l.id, filename: "External", status: "error"})

    exam(l)
    |> Ecto.Changeset.change(
      status: "completed",
      submitted_at: DateTime.utc_now(),
      corrections: %{"q1" => %{"fraction" => 0}}
    )
    |> Repo.update!()

    assert {:ok, generated} =
             Exams.generate(p.id, l.id, 2, "",
               format: "flashcard",
               question_types: question_type_ids(["definition", "long", "cloze"])
             )

    assert generated.status == "in_progress"
    assert generated.format == "flashcard"
    assert generated.generation_examples == []
    assert generated.question_types == ["definition"]
    assert Enum.all?(generated.questions, &(&1["points"] == 1))
    assert Enum.all?(generated.questions, &(&1["origin_id"] != "q1"))
    assert_receive {:flashcard_sources, context, pages, ["definition"]}
    assert Enum.map(pages, & &1.id) == [first.id, second.id]
    assert context.resources == []
    assert context.exams == []
    assert context.pages == pages
  end

  test "server rejects nonquick types and courses without lesson pages" do
    p = profile()
    l = lesson(p)
    page(l)

    assert {:error, _} =
             Exams.generate(p.id, l.id, 2, "",
               format: "flashcard",
               question_types: question_type_ids(["long", "cloze"])
             )

    assert {:error, _} = Exams.generate(p.id, l.id, 2, "", format: "unknown")
    other = lesson(p)
    page(other) |> Ecto.Changeset.change(kind: "example") |> Repo.update!()
    assert {:error, _} = Exams.generate(p.id, other.id, 2, "", format: "flashcard")
  end

  test "resuming generation still excludes new external material" do
    p = profile()
    l = lesson(p)
    page(l)
    {:ok, generated} = Exams.generate(p.id, l.id, 2, "", format: "flashcard")

    generated
    |> Ecto.Changeset.change(
      status: "generation_partial",
      questions: Enum.take(generated.questions, 1)
    )
    |> Repo.update!()

    page(l) |> Ecto.Changeset.change(kind: "example", text: "") |> Repo.update!()
    assert {:ok, resumed} = Exams.resume_generation(p.id, generated.id)
    assert resumed.status == "in_progress"
    assert length(resumed.questions) == 2
    assert Enum.all?(resumed.questions, &(&1["points"] == 1))
    assert resumed.generation_examples == []
  end

  test "quarter points, immutable answers, ordered cards and final score survive reloads" do
    p = profile()
    e = flash_exam(lesson(p))
    assert {:error, _} = Flashcards.advance(p.id, e.id, "q1")
    assert {:error, _} = Flashcards.submit(p.id, e.id, "q2", "quart", sync: true)
    assert {:error, _} = Exams.submit(p.id, e.id, %{}, sync: true)
    assert {:ok, first} = Flashcards.submit(p.id, e.id, "q1", "quart", sync: true)
    assert first.corrections["q1"]["points"] == 0.25
    assert first.card_index == 0
    assert first.status == "in_progress"
    assert {:error, _} = Flashcards.submit(p.id, e.id, "q1", "correct", sync: true)
    {:ok, saved} = Study.save_answers(p.id, e.id, %{"q1" => "correct", "q2" => "future"})
    assert saved.answers["q1"] == "quart"
    assert saved.answers["q2"] == ""
    assert {:ok, next} = Flashcards.advance(p.id, e.id, "q1")
    assert next.card_index == 1
    assert {:error, _} = Flashcards.advance(p.id, e.id, "q1")
    {:ok, last} = Flashcards.submit(p.id, e.id, "q2", "trois quarts", sync: true)
    assert last.corrections["q2"]["points"] == 0.75
    assert last.status == "in_progress"
    assert last.score == nil
    assert {:ok, final} = Flashcards.advance(p.id, e.id, "q2")
    assert final.status == "completed"
    assert final.score == 10.0
    assert Exams.raw_score(final) == {1.0, 2}
    assert final.appreciation
    assert {:error, _} = Flashcards.advance(p.id, e.id, "q2")
    assert {:error, _} = Study.save_answers(p.id, e.id, %{"q2" => "correct"})

    assert_raise Ecto.NoResultsError, fn ->
      Flashcards.submit(profile("Bob").id, e.id, "q1", "x")
    end
  end

  test "failed correction preserves earlier cards and can be retried" do
    p = profile()
    e = flash_exam(lesson(p))
    Flashcards.submit(p.id, e.id, "q1", "moitié", sync: true)
    Flashcards.advance(p.id, e.id, "q1")
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.FailingAI)
    {:ok, failed} = Flashcards.submit(p.id, e.id, "q2", "quart", sync: true)
    assert failed.status == "in_progress"
    assert failed.error
    assert failed.answers["q2"] == "quart"
    assert failed.corrections["q1"]["points"] == 0.5
    refute Map.has_key?(failed.corrections, "q2")
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.FlashcardAI)
    {:ok, retried} = Flashcards.submit(p.id, e.id, "q2", "quart", sync: true)
    assert retried.corrections["q2"]["points"] == 0.25
    assert retried.error == nil
  end

  test "blank answers score zero and grading locks the card" do
    p = profile()
    e = flash_exam(lesson(p), 1)
    {:ok, result} = Flashcards.submit(p.id, e.id, "q1", "", sync: true)
    assert result.corrections["q1"]["points"] == 0
    result |> Ecto.Changeset.change(status: "grading") |> Repo.update!()
    assert {:error, _} = Flashcards.advance(p.id, e.id, "q1")
    assert {:error, _} = Study.save_answers(p.id, e.id, %{"q1" => "change"})
  end

  test "answer comparison preserves meaningful mathematical signs" do
    refute Flashcards.answer_repeated_in_text?(%{"text" => "-2", "answer" => "+2"})
    refute Flashcards.answer_repeated_in_text?(%{"text" => "1,5", "answer" => "15"})
    refute Flashcards.answer_repeated_in_text?(%{"text" => "", "answer" => ""})
  end

  test "source and effort validation rejects cards outside the lesson" do
    pg = page(lesson(profile()))

    q =
      question()
      |> Map.merge(%{
        "source_page_ids" => [pg.id],
        "response_effort" => "direct",
        "answer_basis" => "knowledge"
      })

    assert {[%{"points" => 1}], []} = Flashcards.validate_candidates([q], [pg])

    assert {[], [_]} =
             Flashcards.validate_candidates([Map.put(q, "text", q["answer"])], [pg])

    assert {[], [_]} =
             Flashcards.validate_candidates([Map.put(q, "source_page_ids", ["external"])], [pg])

    assert {[], [_]} =
             Flashcards.validate_candidates([Map.put(q, "response_effort", "developed")], [pg])
  end
end

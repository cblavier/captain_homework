defmodule CaptainHomework.ExamsTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Exams, Study, Repo, AI}

  setup do
    old = Application.fetch_env!(:captain_homework, :ai_provider)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.TestAI)
    on_exit(fn -> Application.put_env(:captain_homework, :ai_provider, old) end)
    :ok
  end

  defp completed(lesson, questions, fractions, time \\ DateTime.utc_now()) do
    exam(lesson, questions)
    |> Ecto.Changeset.change(
      status: "completed",
      submitted_at: time,
      corrections:
        Map.new(Enum.zip(questions, fractions), fn {q, f} -> {q["id"], %{"fraction" => f}} end)
    )
    |> Repo.update!()
  end

  test "prioritizes lowest relative scores, at most three" do
    p = profile()
    l = lesson(p)
    e = completed(l, Enum.map(1..5, &question("q#{&1}")), [0.75, 0, 0.5, 0.25, 1])
    assert Enum.map(Exams.retry_questions([e], 10), & &1["id"]) == ["q2", "q4", "q3"]
    assert length(Exams.retry_questions([e], 1)) == 1
  end

  test "legacy general instructions are ignored and each control keeps its own instructions" do
    now = NaiveDateTime.utc_now()

    Repo.insert_all("settings", [
      %{id: 1, instructions: "Ancien prompt général", inserted_at: now, updated_at: now}
    ])

    p = profile()
    l = lesson(p)
    page(l)

    old =
      exam(l) |> Ecto.Changeset.change(instructions: "Instructions historiques") |> Repo.update!()

    {:ok, first} = Exams.generate(p.id, l.id, 2, "Insister sur les dates", [])
    assert first.instructions == "Insister sur les dates"
    {:ok, second} = Exams.generate(p.id, l.id, 2, "", [])
    assert second.instructions == ""
    assert Repo.get!(Study.Exam, old.id).instructions == "Instructions historiques"
    assert Repo.get!(Study.Exam, first.id).instructions == first.instructions
  end

  test "uses most recent attempt and drops a now-mastered question" do
    p = profile()
    l = lesson(p)
    old = completed(l, [question("old")], [0], DateTime.add(DateTime.utc_now(), -60))
    new_question = question("new") |> Map.put("origin_id", "old")
    new = completed(l, [new_question], [1])
    assert Exams.retry_questions([old, new], 10) == []
    partial = %{new | corrections: %{"new" => %{"fraction" => 0.5}}}
    assert [^new_question] = Exams.retry_questions([old, partial], 10)
  end

  test "generation fills remaining slots and preserves copied content" do
    p = profile()
    l = lesson(p)
    page(l)
    completed(l, [question("failed")], [0])
    {:ok, e} = Exams.generate(p.id, l.id, 4, "", [])
    assert length(e.questions) == 4
    assert hd(e.questions)["origin_id"] == "failed"
    assert hd(e.questions)["prompt"] == question()["prompt"]
    assert hd(e.questions)["id"] != "failed"
    assert e.instructions == ""
  end

  test "generation requires readable lessons and valid count" do
    p = profile()
    l = lesson(p)
    assert {:error, _} = Exams.generate(p.id, l.id, 10, "", [])
    pg = page(l)
    Study.update_page(pg, "")
    assert {:error, _} = Exams.generate(p.id, l.id, 10, "", [])
    assert {:error, _} = Exams.generate(p.id, l.id, 31, "", [])
  end

  test "retries stay within the current lesson and exclude other subjects and children" do
    p = profile()
    target = lesson(p)
    page(target)
    completed(target, [question("same-lesson")], [0.25])
    completed(lesson(p), [question("same-subject")], [0.25])
    completed(lesson(p, "anglais"), [question("other-subject")], [0])
    completed(lesson(profile("Bob")), [question("other-child")], [0])

    {:ok, generated} = Exams.generate(p.id, target.id, 4, "", [])
    origins = Enum.map(generated.questions, & &1["origin_id"])
    assert hd(origins) == "same-lesson"
    refute "same-subject" in origins
    refute "other-subject" in origins
    refute "other-child" in origins
  end

  test "validates generated questions including cloze and diagrams" do
    assert {:error, _} = AI.validate_questions([], 10)
    assert {:error, _} = AI.validate_questions([%{}], 1)
    assert {:error, _} = AI.validate_questions([question("q", "mcq")], 1)
    assert {:error, _} = AI.validate_questions([question("q", "diagram")], 1)

    q =
      question("q", "cloze")
      |> Map.merge(%{"slots" => ["1"], "text" => "Une cellule a un {{1}}."})

    assert {:ok, [^q]} = AI.validate_questions([q], 1)
  end

  test "quarter-point fractions and blank answers determine final mark" do
    p = profile()
    l = lesson(p)
    e = exam(l, Enum.map(1..4, &question("q#{&1}")))

    {:ok, result} =
      Exams.submit(
        p.id,
        e.id,
        %{"q1" => "quart", "q2" => "moitié", "q3" => "trois quarts", "q4" => ""},
        sync: true
      )

    assert result.status == "completed"
    assert result.appreciation == "Des connaissances solides ; précise tes justifications."
    assert result.score == 7.5
    assert result.corrections["q1"]["points"] == 1.0
    assert result.corrections["q4"]["points"] == 0
    assert {:error, :already_submitted} = Exams.submit(p.id, e.id, %{}, sync: true)
  end

  test "marks are rounded to the nearest quarter without changing raw points" do
    assert Exams.round_score(16.71) == 16.75
    assert Exams.round_score(16.12) == 16.0
    assert Exams.round_score(16.125) == 16.25
    assert Exams.round_score(9.99) == 10.0

    assert Exams.raw_score(%{
             questions: [%{"points" => 29}],
             corrections: %{"q" => %{"points" => 24}}
           }) == {24, 29}
  end

  test "MCQ is scored deterministically even if model gives wrong grade" do
    q = question("q", "mcq") |> Map.merge(%{"options" => ["A", "B"], "answer" => "B"})
    e = %{questions: [q], answers: %{"q" => "A"}}

    assert {:ok, corrections, score} =
             Exams.validate_grades(e, [%{"id" => "q", "fraction" => 1, "feedback" => "Incorrect"}])

    assert score == 0.0
    assert corrections["q"]["fraction"] == 0
  end

  test "rejects incomplete, duplicate and invalid fractions" do
    e = %{questions: [question()], answers: %{}}
    assert {:error, _} = Exams.validate_grades(e, [])

    assert {:error, _} =
             Exams.validate_grades(e, [%{"id" => "q1", "fraction" => 0.3, "feedback" => "x"}])

    grade = %{"id" => "q1", "fraction" => 1, "feedback" => "x"}
    assert {:error, _} = Exams.validate_grades(e, [grade, grade])
  end

  test "interrupted grading can be retried after timeout" do
    p = profile()
    e = exam(lesson(p))

    e =
      e
      |> Ecto.Changeset.change(
        status: "grading",
        grading_started_at: DateTime.add(DateTime.utc_now(), -400)
      )
      |> Repo.update!()

    Exams.recover_stale(e)
    assert Study.get_exam!(p.id, e.id).status == "in_progress"
  end

  test "a failed correction preserves answers and enables retry" do
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.FailingAI)
    p = profile()
    e = exam(lesson(p))
    {:ok, result} = Exams.submit(p.id, e.id, %{"q1" => "ma réponse"}, sync: true)
    assert result.status == "in_progress"
    assert result.answers["q1"] == "ma réponse"
    assert result.error == "Service indisponible"
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.TestAI)
    {:ok, result} = Exams.submit(p.id, e.id, result.answers, sync: true)
    assert result.status == "completed"
  end

  test "an old grading attempt cannot overwrite a newer attempt" do
    p = profile()
    e = exam(lesson(p))
    old = DateTime.add(DateTime.utc_now(), -400)
    current = DateTime.utc_now()
    e |> Ecto.Changeset.change(status: "grading", grading_started_at: current) |> Repo.update!()

    Exams.grade(%{
      e
      | status: "grading",
        grading_started_at: old,
        answers: %{"q1" => "ma réponse"}
    })

    assert Study.get_exam!(p.id, e.id).status == "grading"
  end
end

defmodule CaptainHomework.GenerationTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.{AI, Exams, Repo, Study, SequenceAI}

  setup do
    old = AI.provider()
    Application.put_env(:captain_homework, :ai_provider, SequenceAI)
    on_exit(fn -> Application.put_env(:captain_homework, :ai_provider, old) end)
    p = profile()
    l = lesson(p)
    page(l)
    %{profile: p, lesson: l}
  end

  defp sequence(responses) do
    start_supervised!(%{
      id: SequenceAI,
      start:
        {Agent, :start_link, [fn -> %{responses: responses, calls: []} end, [name: SequenceAI]]}
    })
  end

  defp q(name), do: question(name) |> Map.put("prompt", "Question #{name}")
  defp calls, do: Agent.get(SequenceAI, & &1.calls)

  test "selected types filter generated questions and survive partial recovery", %{
    profile: p,
    lesson: l
  } do
    mcq = q("allowed") |> Map.merge(%{"type" => "mcq", "options" => ["A", "B"], "answer" => "A"})

    sequence([
      {:ok, [q("forbidden")]},
      {:ok, []},
      {:ok, []},
      {:ok, [q("forbidden fallback")]},
      {:ok, [mcq]}
    ])

    assert {:ok, partial} =
             Exams.generate(p.id, l.id, 1, "", question_types: question_type_ids(["mcq"]))

    assert partial.status == "generation_partial"
    assert partial.questions == []
    assert partial.question_types == ["mcq"]
    assert Enum.all?(calls(), &(&1.instructions =~ "TYPES AUTORISÉS EXCLUSIVEMENT : mcq."))
    assert {:ok, complete} = Exams.resume_generation(p.id, partial.id)
    assert complete.status == "in_progress"
    assert Enum.map(complete.questions, & &1["type"]) == ["mcq"]
  end

  test "empty or invalid type selections do not create a control", %{profile: p, lesson: l} do
    assert {:error, _} = Exams.generate(p.id, l.id, 1, "", question_types: [])
    assert {:error, _} = Exams.generate(p.id, l.id, 1, "", question_types: ["unknown"])
    assert Study.get_lesson!(p.id, l.id).exams == []
  end

  test "previous mistakes cannot reintroduce an excluded type", %{profile: p, lesson: l} do
    old = exam(l, [q("previous")])

    old
    |> Ecto.Changeset.change(
      status: "completed",
      submitted_at: DateTime.utc_now(),
      corrections: %{"previous" => %{"fraction" => 0}}
    )
    |> Repo.update!()

    mcq = q("new") |> Map.merge(%{"type" => "mcq", "options" => ["A", "B"], "answer" => "A"})
    sequence([{:ok, [mcq]}])

    assert {:ok, generated} =
             Exams.generate(p.id, l.id, 1, "", question_types: question_type_ids(["mcq"]))

    assert Enum.map(generated.questions, & &1["type"]) == ["mcq"]
    assert [%{kept: []}] = calls()
  end

  test "generation duration is persisted and adds attempts without counting the pause", %{
    profile: p,
    lesson: l
  } do
    sequence([{:ok, [q("first")]}, {:error, "Interrupted"}, {:ok, [q("next")]}])
    {:ok, partial} = Exams.generate(p.id, l.id, 2, "")
    assert is_integer(partial.generation_duration_ms)

    partial
    |> Ecto.Changeset.change(
      generation_duration_ms: 60_000,
      generation_started_at: DateTime.add(DateTime.utc_now(), -3600)
    )
    |> Repo.update!()

    {:ok, complete} = Exams.resume_generation(p.id, partial.id)
    assert complete.generation_duration_ms >= 60_000
    assert complete.generation_duration_ms < 120_000

    assert Repo.get!(Study.Exam, complete.id).generation_duration_ms ==
             complete.generation_duration_ms
  end

  test "repairs only invalid questions and reports their precise error", %{profile: p, lesson: l} do
    bad = q("bad") |> Map.merge(%{"type" => "mcq", "options" => ["A", "B"], "answer" => "C"})
    sequence([{:ok, [q("kept"), bad]}, {:ok, [q("fixed")]}])
    owner = self()

    assert {:ok, exam} =
             Exams.generate(p.id, l.id, 2, "", progress: &send(owner, {:progress, &1}))

    assert exam.status == "in_progress"
    assert Enum.map(exam.questions, & &1["prompt"]) == ["Question kept", "Question fixed"]
    assert [%{count: 2}, %{count: 1, instructions: feedback, kept: [kept]}] = calls()
    assert feedback =~ "QCM"
    assert feedback =~ "réponse identique"
    assert kept["prompt"] == "Question kept"
    assert_receive {:progress, "0 questions prêtes sur 2 · préparation…"}
    assert_receive {:progress, "1 questions prêtes sur 2 · ajustement de 1 question…"}
  end

  test "two repairs then a simple fallback, followed by persistent partial recovery", %{
    profile: p,
    lesson: l
  } do
    sequence([
      {:ok, [q("kept"), %{}]},
      {:ok, [%{}]},
      {:ok, []},
      {:ok, [%{}]},
      {:ok, [q("missing")]}
    ])

    assert {:ok, partial} = Exams.generate(p.id, l.id, 2, "", [])
    assert partial.status == "generation_partial"
    assert length(partial.questions) == 1
    assert length(calls()) == 4
    assert List.last(calls()).instructions =~ "REPLI OBLIGATOIRE"
    assert partial.generation_errors != []
    assert Repo.get!(Study.Exam, partial.id).questions == partial.questions
    assert {:error, :already_submitted} = Exams.submit(p.id, partial.id, %{}, sync: true)
    assert {:ok, complete} = Exams.resume_generation(p.id, partial.id)
    assert complete.id == partial.id
    assert complete.status == "in_progress"
    assert hd(complete.questions) == hd(partial.questions)
    assert List.last(calls()).count == 1
    assert {:error, _} = Exams.resume_generation(p.id, complete.id)
  end

  test "API errors stop retries and retain accepted questions", %{profile: p, lesson: l} do
    sequence([{:ok, [q("kept")]}, {:error, "Quota atteint"}])
    assert {:ok, partial} = Exams.generate(p.id, l.id, 2, "", [])
    assert length(calls()) == 2
    assert partial.status == "generation_partial"
    assert partial.generation_errors == ["Quota atteint"]
    assert length(partial.questions) == 1
  end

  test "duplicates are replaced and surplus questions are bounded", %{profile: p, lesson: l} do
    sequence([{:ok, [q("same"), q("same")]}, {:ok, [q("next"), q("extra")]}])
    assert {:ok, exam} = Exams.generate(p.id, l.id, 2, "", [])
    assert Enum.map(exam.questions, & &1["prompt"]) == ["Question same", "Question next"]
    assert List.last(calls()).instructions =~ "répète un énoncé"
  end

  test "three identical instructions on distinct images are retained", %{profile: p, lesson: l} do
    resource = Repo.insert!(%Study.Resource{lesson_id: l.id, filename: "images", status: "ready"})

    pages =
      for n <- 1..3 do
        key = "#{Ecto.UUID.generate()}.png"
        File.mkdir_p!(CaptainHomework.Uploads.directory())
        File.write!(CaptainHomework.Uploads.path(key), "image #{n}")
        on_exit(fn -> File.rm(CaptainHomework.Uploads.path(key)) end)

        Repo.insert!(%Study.Page{
          lesson_id: l.id,
          resource_id: resource.id,
          kind: "resource",
          filename: key,
          storage_key: key,
          content_type: "image/png",
          text: "Position #{n}",
          status: "ready"
        })
      end

    questions =
      Enum.map(pages, fn page ->
        q("Observe l’image")
        |> Map.merge(%{
          "image_ids" => [page.id],
          "objective" => "Identifier une position",
          "skill" => "interpret"
        })
      end)

    sequence([{:ok, questions}])
    assert {:ok, exam} = Exams.generate(p.id, l.id, 3, "Utilise les images")
    on_exit(fn -> CaptainHomework.Exams.Illustrations.delete_exam_images(exam) end)
    assert exam.status == "in_progress"
    assert length(exam.questions) == 3
    assert Enum.map(exam.questions, & &1["image_ids"]) == Enum.map(pages, &[&1.id])
    assert length(calls()) == 1
  end

  test "diagnostics are safe for malformed values and unmatched holes" do
    assert {[], [_]} = AI.inspect_questions(nil)
    assert {[], errors} = AI.inspect_questions([%{"slots" => nil}, "invalid"])
    assert length(errors) > 1

    bad =
      q("cloze") |> Map.merge(%{"type" => "cloze", "text" => "{{1}} et {{2}}", "slots" => ["1"]})

    assert [reason] = AI.question_errors(bad)
    assert reason =~ "correspondance exacte"
  end

  test "stale generation becomes recoverable without losing its questions", %{lesson: l} do
    exam =
      exam(l, [q("saved")])
      |> Ecto.Changeset.change(
        status: "generating",
        generation_target: 2,
        generation_started_at: DateTime.add(DateTime.utc_now(), -6)
      )
      |> Repo.update!()

    Exams.recover_stale(exam)
    restored = Repo.get!(Study.Exam, exam.id)
    assert restored.status == "generation_partial"
    assert restored.questions == exam.questions
  end
end

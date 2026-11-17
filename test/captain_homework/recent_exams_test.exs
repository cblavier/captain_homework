defmodule CaptainHomework.RecentExamsTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.{ExamShares, Study}

  test "history includes every state, isolates the pupil and excludes shared copies and jobs" do
    alice = profile()
    lesson = lesson(alice)

    controls =
      for status <- ~w(in_progress generating generation_partial grading completed) do
        exam(lesson)
        |> Ecto.Changeset.change(status: status, score: if(status == "completed", do: 14.0))
        |> Repo.update!()
      end

    source = hd(controls)
    {:ok, _, token} = ExamShares.create(alice.id, source.id, "fill")
    {:ok, _, _copy} = ExamShares.open(token, "visitor")
    exam(lesson(profile("Marius")))

    exam(lesson)
    |> Ecto.Changeset.change(regeneration_source_id: source.id)
    |> Repo.update!()

    page = Study.recent_exams(alice.id)
    assert MapSet.new(page.exams, & &1.id) == MapSet.new(controls, & &1.id)
    refute page.more?
    assert Enum.all?(page.exams, &Ecto.assoc_loaded?(&1.lesson))

    assert Study.exam_status_counts(alice.id) == %{
             lesson.subject => %{corrected: 1, unsubmitted: 3}
           }
  end

  test "cursor pagination handles identical dates and new entries without duplicates" do
    alice = profile()
    lesson = lesson(alice)

    controls =
      for _ <- 1..7 do
        exam(lesson)
        |> Ecto.Changeset.change(inserted_at: ~U[2026-11-01 12:00:00.000000Z])
        |> Repo.update!()
      end

    first = Study.recent_exams(alice.id)
    assert length(first.exams) == 5
    assert first.more?
    new = exam(lesson)
    second = Study.recent_exams(alice.id, before: first.cursor)
    assert length(second.exams) == 2
    refute second.more?
    ids = Enum.map(first.exams ++ second.exams, & &1.id)
    assert ids == Enum.sort(Enum.map(controls, & &1.id), :desc)
    refute new.id in ids
  end
end

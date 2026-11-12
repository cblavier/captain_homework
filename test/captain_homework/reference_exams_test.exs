defmodule CaptainHomework.ReferenceExamsTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.{ReferenceExams, Repo, Study, Exams}

  test "references are scoped to a child and subject, independently of lessons" do
    alice = profile()
    reference = reference_exam(alice)
    other = reference_exam(profile("Marius"))
    english = reference_exam(alice, "anglais")

    {:ok, page} =
      ReferenceExams.add_page(reference, %{
        filename: "page.png",
        storage_key: "reference.png",
        content_type: "image/png"
      })

    assert page.lesson_id == nil
    assert Study.get_page!(alice.id, page.id).reference_exam_id == reference.id
    assert_raise Ecto.NoResultsError, fn -> Study.get_page!(other.profile_id, page.id) end

    assert_raise Ecto.NoResultsError, fn ->
      ReferenceExams.get!(other.profile_id, reference.id)
    end

    assert Enum.map(ReferenceExams.list(alice.id, "svt"), & &1.id) == [reference.id]
    assert {:error, _} = ReferenceExams.selection(alice.id, "svt", english.id, "classic")
    assert {:error, _} = ReferenceExams.selection(alice.id, "svt", other.id, "classic")
    assert {:error, _} = ReferenceExams.selection(alice.id, "svt", "invalid", "classic")
    assert {:ok, nil, []} = ReferenceExams.selection(alice.id, "svt", reference.id, "flashcard")
    empty_lesson = lesson(alice)
    assert {:ok, _} = Study.delete_lesson(alice.id, empty_lesson.id)
    assert ReferenceExams.get!(alice.id, reference.id).pages != []
  end

  test "names and dates are required and can be edited" do
    alice = profile()

    assert {:error, _} =
             ReferenceExams.create(alice, "svt", %{"title" => " ", "date" => "invalid"})

    reference = reference_exam(alice)

    assert {:ok, saved} =
             ReferenceExams.update(alice.id, reference.id, %{
               "title" => "  Cellules  ",
               "date" => "2026-11-01"
             })

    assert saved.title == "Cellules"
    assert saved.date == ~D[2026-11-01]
  end

  test "deleting a reference preserves evaluations and their lessons" do
    alice = profile()
    reference = reference_exam(alice)
    l = lesson(alice)
    e = exam(l) |> Ecto.Changeset.change(reference_exam_id: reference.id) |> Repo.update!()

    {:ok, p} =
      ReferenceExams.add_page(reference, %{
        filename: "page.png",
        storage_key: "nonexistent-reference.png",
        content_type: "image/png"
      })

    assert {:ok, _} = ReferenceExams.delete(alice.id, reference.id)
    assert Repo.get(Study.Page, p.id) == nil
    assert Study.get_exam!(alice.id, e.id).reference_exam_id == nil
    assert Study.get_lesson!(alice.id, l.id)
  end

  test "no reference is used by default and invalid selections cannot create an evaluation" do
    alice = profile()
    l = lesson(alice)
    page(l)
    reference = reference_exam(alice)
    assert {:error, _} = Exams.generate(alice.id, l.id, 1, "", reference_exam_id: reference.id)
    assert Repo.aggregate(Study.Exam, :count) == 0
    assert {:ok, generated} = Exams.generate(alice.id, l.id, 1, "")
    assert generated.reference_exam_id == nil
    assert generated.generation_examples == []
  end
end

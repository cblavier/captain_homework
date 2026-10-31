defmodule CaptainHomework.StudyTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.Study

  test "subjects are alphabetically sorted" do
    assert Enum.map(Study.subjects(), & &1.name) == [
             "Anglais",
             "Espagnol",
             "Français",
             "Histoire-Géographie",
             "Latin",
             "Mathématiques",
             "Physique-Chimie",
             "SVT",
             "Technologie"
           ]
  end

  test "disabled subjects persist per child without deleting lessons or exams" do
    a = profile()
    b = profile("Marius")
    l = lesson(a)
    e = exam(l)
    assert length(Study.enabled_subjects(a)) == 9
    assert {:ok, _} = Study.save_subjects(a, [])
    assert Study.enabled_subjects(Study.get_profile(a.id)) == []
    assert length(Study.enabled_subjects(Study.get_profile(b.id))) == 9
    assert Study.get_lesson!(a.id, l.id).id == l.id
    assert Study.get_exam!(a.id, e.id).id == e.id
    assert {:error, :invalid_subjects} = Study.save_subjects(a, ["unknown"])
    assert {:ok, _} = Study.save_subjects(Study.get_profile(a.id), Study.subject_ids())
    assert length(Study.enabled_subjects(Study.get_profile(a.id))) == 9
    assert Study.lessons(a.id, "svt") |> Enum.any?(&(&1.id == l.id))
  end

  test "lessons belong to one child and carry today's date" do
    a = profile()
    b = profile("Marius")
    l = lesson(a)
    assert l.date == Study.today()
    assert Study.lessons(b.id, "svt") == []
    assert_raise Ecto.NoResultsError, fn -> Study.get_lesson!(b.id, l.id) end
  end

  test "lesson validation rejects empty names and unsupported subjects" do
    p = profile()
    assert {:error, _} = Study.create_lesson(p, %{"title" => "", "subject" => "svt"})
    assert {:error, _} = Study.create_lesson(p, %{"title" => "Cours", "subject" => "autre"})
  end

  test "pages and exams cannot be fetched with another child profile" do
    a = profile()
    b = profile("Marius")
    l = lesson(a)
    pg = page(l)
    e = exam(l)
    assert_raise Ecto.NoResultsError, fn -> Study.get_page!(b.id, pg.id) end
    assert_raise Ecto.NoResultsError, fn -> Study.get_exam!(b.id, e.id) end
  end

  test "draft answers persist and unknown answer keys are ignored" do
    p = profile()
    l = lesson(p)
    e = exam(l)

    assert {:ok, _} =
             Study.save_answers(p.id, e.id, %{"q1" => "ma réponse", "intrus" => "secret"})

    assert Study.get_exam!(p.id, e.id).answers == %{"q1" => "ma réponse"}
  end

  test "grading and completed copies cannot be edited" do
    p = profile()
    l = lesson(p)
    e = exam(l)

    for status <- ["grading", "completed"] do
      e |> Ecto.Changeset.change(status: status) |> CaptainHomework.Repo.update!()
      assert {:error, :already_submitted} = Study.save_answers(p.id, e.id, %{"q1" => "modifiée"})
    end
  end
end

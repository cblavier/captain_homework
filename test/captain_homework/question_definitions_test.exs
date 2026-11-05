defmodule CaptainHomework.QuestionDefinitionsTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.{QuestionDefinitions, Study, Exams}
  alias Study.{QuestionDefinition, ExamQuestionDefinition}

  defp attrs(extra \\ %{}) do
    Map.merge(
      %{
        name: "Question partagée",
        subjects: ["svt", "histoire-geo"],
        modes: ["classic", "flashcard"],
        response_kind: "short_text",
        instruction_kind: "fixed",
        instruction: "Définis la notion suivante.",
        content_kind: "text",
        content_presence: "required",
        work_duration: "medium"
      },
      extra
    )
  end

  test "catalogue is shared, mode eligibility is independent of duration, invalid definitions are rejected" do
    {:ok, type} = QuestionDefinitions.save(%QuestionDefinition{}, attrs())

    assert QuestionDefinitions.available("svt") == [type]

    assert [%{id: id} = available] =
             QuestionDefinitions.available("histoire-geo")

    assert id == type.id
    assert QuestionDefinitions.mode_allowed?(available, "flashcard")
    assert QuestionDefinitions.available("anglais") == []

    for invalid <- [
          %{modes: []},
          %{subjects: []},
          %{subjects: ["invalid"]},
          %{response_kind: "html"},
          %{instruction: ""}
        ] do
      assert {:error, _} = QuestionDefinitions.save(%QuestionDefinition{}, attrs(invalid))
    end

    assert {:error, _} =
             QuestionDefinitions.save(%QuestionDefinition{}, attrs(%{name: "QUESTION PARTAGÉE"}))
  end

  test "unused deletion is physical, used deletion preserves immutable exam snapshots" do
    {:ok, unused} = QuestionDefinitions.save(%QuestionDefinition{}, attrs())
    {:ok, _} = QuestionDefinitions.delete(unused.id)
    refute Repo.get(QuestionDefinition, unused.id)
    assert QuestionDefinitions.available("svt") == []
    {:ok, used} = QuestionDefinitions.save(%QuestionDefinition{}, attrs())
    exam = exam(lesson(profile()))
    QuestionDefinitions.attach!(exam, [used])
    assert QuestionDefinitions.exam_count(used.id) == 1
    other_exam = exam(lesson(profile("Marius")))
    QuestionDefinitions.attach!(other_exam, [used])
    assert QuestionDefinitions.exam_count(used.id) == 2
    {:ok, changed} = QuestionDefinitions.save(used, %{name: "Nouveau nom"})
    assert Repo.get_by!(ExamQuestionDefinition, exam_id: exam.id).snapshot["name"] == used.name
    {:ok, _} = QuestionDefinitions.delete(changed.id)
    assert Repo.get!(QuestionDefinition, changed.id).deleted_at
    assert QuestionDefinitions.list() == []
    assert_raise Ecto.NoResultsError, fn -> QuestionDefinitions.get!(changed.id) end
    assert Study.get_exam!(profile().id, exam.id).questions == exam.questions
  end

  test "an empty catalogue never falls back to built-in or per-student types" do
    assert QuestionDefinitions.available("svt") == []
    assert {:error, :invalid_types} = QuestionDefinitions.resolve("svt", ["definition"])
    {:ok, type} = QuestionDefinitions.save(%QuestionDefinition{}, attrs())
    assert {:ok, [^type]} = QuestionDefinitions.resolve("svt", [type.id])
    assert {:error, :invalid_types} = QuestionDefinitions.resolve("anglais", [type.id])
    assert {:error, :invalid_types} = QuestionDefinitions.resolve("svt", ["definition"])
  end

  test "deletion checks the exact definition, not another type sharing its renderer" do
    {:ok, used} = QuestionDefinitions.save(%QuestionDefinition{}, attrs())
    {:ok, unused} = QuestionDefinitions.save(%QuestionDefinition{}, attrs(%{name: "Même rendu"}))
    control = exam(lesson(profile()))
    QuestionDefinitions.attach!(control, [used])
    {:ok, _} = QuestionDefinitions.delete(unused.id)
    refute Repo.get(QuestionDefinition, unused.id)
    {:ok, changed} = QuestionDefinitions.save(used, %{instruction: "Nouvelle consigne"})
    {:ok, _} = QuestionDefinitions.delete(changed.id)
    [snapshot] = QuestionDefinitions.for_exam(control)
    assert snapshot.instruction == used.instruction
    assert snapshot.name == used.name
    assert QuestionDefinitions.instructions([snapshot]) =~ used.instruction
  end

  test "seed is repeatable, includes the new types and excludes true false" do
    {:ok, _} = QuestionDefinitions.seed!()
    types = QuestionDefinitions.list()
    assert length(types) >= 10

    for name <- [
          "Définition",
          "Classement chronologique",
          "Carte à compléter",
          "Compréhension orale",
          "Prononciation",
          "Dessin de géométrie"
        ] do
      assert Enum.any?(types, &(&1.name == name))
    end

    refute Enum.any?(types, &String.contains?(&1.name, "Vrai"))
    {:ok, _} = QuestionDefinitions.seed!()
    assert Enum.map(QuestionDefinitions.list(), & &1.id) == Enum.map(types, & &1.id)
  end

  test "generation consumes common types and stores references, unsupported media are explicit" do
    previous = Application.fetch_env!(:captain_homework, :ai_provider)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.TestAI)
    on_exit(fn -> Application.put_env(:captain_homework, :ai_provider, previous) end)
    p = profile()
    l = lesson(p)
    page(l)
    {:ok, type} = QuestionDefinitions.save(%QuestionDefinition{}, attrs())
    assert {:ok, exam} = Exams.generate(p.id, l.id, 1, "", question_types: [type.id])
    assert Repo.get_by!(ExamQuestionDefinition, exam_id: exam.id).definition_id == type.id

    {:ok, voice} =
      QuestionDefinitions.save(
        %QuestionDefinition{},
        attrs(%{name: "Oral", response_kind: "recording"})
      )

    assert {:error, message} = Exams.generate(p.id, l.id, 1, "", question_types: [voice.id])
    assert message =~ "pas encore disponible"
  end
end

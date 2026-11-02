defmodule CaptainHomework.SubjectQuestionTypesTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.{SubjectQuestionTypes, Exams, Repo, Study}

  setup do
    previous = Application.fetch_env!(:captain_homework, :ai_provider)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.TestAI)
    on_exit(fn -> Application.put_env(:captain_homework, :ai_provider, previous) end)
    :ok
  end

  test "defaults and changes are scoped to child and subject, including an empty list" do
    alice = profile()
    other = profile("Marius")
    defaults = SubjectQuestionTypes.defaults()
    assert SubjectQuestionTypes.list(alice.id, "svt") == defaults

    for type <- defaults do
      assert {:ok, _} = SubjectQuestionTypes.delete(alice.id, "svt", type["id"])
    end

    assert SubjectQuestionTypes.list(alice.id, "svt") == []
    assert SubjectQuestionTypes.list(alice.id, "anglais") == defaults
    assert SubjectQuestionTypes.list(other.id, "svt") == defaults
    assert {:error, _} = SubjectQuestionTypes.resolve(alice.id, "svt", ["long"])
  end

  test "custom types need no format and reject duplicate names" do
    p = profile()

    attrs = %{
      "label" => " Calcul mental ",
      "description" => "Calculer de tête."
    }

    assert {:ok, settings} = SubjectQuestionTypes.add(p.id, "mathematiques", attrs)
    type = List.last(settings.types)
    assert type["label"] == "Calcul mental"
    assert {:ok, [^type]} = SubjectQuestionTypes.resolve(p.id, "mathematiques", [type["id"]])
    assert {:error, _} = SubjectQuestionTypes.add(p.id, "mathematiques", attrs)
    assert type["format"] == "long"
    assert type["format_inferred"] == true
    assert {:ok, _} = SubjectQuestionTypes.add(p.id, "svt", Map.put(attrs, "format", "arbitrary"))
    assert {:error, _} = SubjectQuestionTypes.add(p.id, "svt", %{attrs | "label" => "   "})
    assert {:error, _} = SubjectQuestionTypes.resolve(p.id, "anglais", [type["id"]])
  end

  test "generation snapshots selected custom instructions and preserves existing controls on deletion" do
    previous = Application.fetch_env!(:captain_homework, :ai_provider)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.TestAI)
    on_exit(fn -> Application.put_env(:captain_homework, :ai_provider, previous) end)
    p = profile()
    l = lesson(p)
    page(l)

    {:ok, settings} =
      SubjectQuestionTypes.add(p.id, "svt", %{
        "label" => "Comparer",
        "description" => "Comparer deux éléments du cours.",
        "format" => "long"
      })

    type = List.last(settings.types)
    {:ok, generated} = Exams.generate(p.id, l.id, 2, "", question_types: [type["id"]])
    assert generated.status == "in_progress"
    assert generated.question_types == ["long"]
    assert generated.instructions =~ "Comparer deux éléments du cours."
    assert generated.instructions =~ "Le format a été déduit une fois"
    refute generated.instructions =~ "- QCM (format"
    assert Enum.all?(generated.questions, &(&1["type"] == "long"))
    {:ok, _} = SubjectQuestionTypes.delete(p.id, "svt", type["id"])
    saved = Repo.get!(Study.Exam, generated.id)
    assert saved.questions == generated.questions
    assert saved.instructions == generated.instructions
    assert {:error, _} = Exams.generate(p.id, l.id, 2, "", question_types: [type["id"]])
  end
end

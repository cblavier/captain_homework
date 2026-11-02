defmodule CaptainHomework.QuestionTypeCatalogueTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures

  alias CaptainHomework.{
    QuestionTypeCatalogue,
    QuestionTypes,
    Repo,
    Study,
    SubjectQuestionTypes,
    WorkDuration
  }

  alias CaptainHomework.Study.SubjectQuestionSettings

  test "each subject has a distinct catalogue with valid duration and render formats" do
    p = profile()

    for subject <- Study.subjects() do
      catalogue = QuestionTypeCatalogue.for_subject(subject.id)
      assert length(catalogue) in 7..9
      assert length(Enum.uniq_by(catalogue, & &1["id"])) == length(catalogue)
      assert Enum.all?(catalogue, &(&1["format"] in QuestionTypes.ids()))
      assert Enum.all?(catalogue, &(&1["work_duration"] in WorkDuration.values()))
      assert {:ok, settings} = SubjectQuestionTypes.seed_catalogue(p.id, subject.id)
      assert settings.types == catalogue
      assert {:ok, repeated} = SubjectQuestionTypes.seed_catalogue(p.id, subject.id)
      assert repeated.types == catalogue

      assert {:ok, ^catalogue} =
               SubjectQuestionTypes.resolve(p.id, subject.id, Enum.map(catalogue, & &1["id"]))
    end

    english =
      Enum.find(SubjectQuestionTypes.list(p.id, "anglais"), &(&1["label"] == "Traduction"))

    latin = Enum.find(SubjectQuestionTypes.list(p.id, "latin"), &(&1["label"] == "Traduction"))
    assert english["work_duration"] == "medium"
    assert latin["work_duration"] == "long"
  end

  test "seeding preserves custom types and existing choices for each child" do
    p = profile()
    other = profile("Marius")

    qcm = %{
      "id" => "custom-qcm",
      "label" => "QCM",
      "description" => "Consigne personnelle",
      "format" => "mcq",
      "work_duration" => "long"
    }

    custom = %{
      "id" => "custom",
      "label" => "Mon exercice",
      "format" => "long",
      "work_duration" => "quick"
    }

    Repo.insert!(%SubjectQuestionSettings{profile_id: p.id, subject: "svt", types: [qcm, custom]})
    assert {:ok, settings} = SubjectQuestionTypes.seed_catalogue(p.id, "svt")
    assert Enum.find(settings.types, &(&1["label"] == "QCM"))["id"] == "custom-qcm"
    assert Enum.find(settings.types, &(&1["label"] == "QCM"))["work_duration"] == "long"
    assert custom in settings.types
    assert SubjectQuestionTypes.list(other.id, "svt") == SubjectQuestionTypes.defaults()
  end

  test "durations are validated and saved with new custom types" do
    p = profile()
    previous = Application.fetch_env!(:captain_homework, :ai_provider)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.TestAI)
    on_exit(fn -> Application.put_env(:captain_homework, :ai_provider, previous) end)

    attrs = %{
      "label" => "Calcul mental",
      "description" => "Calculer de tête",
      "work_duration" => "quick"
    }

    assert {:error, invalid} =
             SubjectQuestionTypes.add(
               p.id,
               "mathematiques",
               Map.put(attrs, "work_duration", "other")
             )

    assert Keyword.has_key?(invalid.errors, :work_duration)
    assert {:ok, _} = SubjectQuestionTypes.add(p.id, "mathematiques", attrs)

    type =
      List.last(
        Repo.get_by!(SubjectQuestionSettings, profile_id: p.id, subject: "mathematiques").types
      )

    assert type["work_duration"] == "quick"
    assert WorkDuration.minutes(type["work_duration"]) == 1
    assert WorkDuration.minutes("medium") == 3
    assert WorkDuration.minutes("long") == 6
  end
end

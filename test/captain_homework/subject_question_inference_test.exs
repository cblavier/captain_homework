defmodule CaptainHomework.SubjectQuestionInferenceTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.{Repo, SubjectQuestionTypes}
  alias CaptainHomework.Study.SubjectQuestionSettings

  setup do
    previous = Application.fetch_env!(:captain_homework, :ai_provider)
    Application.put_env(:captain_homework, :ai_provider, CaptainHomework.InferenceAI)
    on_exit(fn -> Application.put_env(:captain_homework, :ai_provider, previous) end)
    %{profile: profile()}
  end

  test "inference is stored once and duplicate names do not call it again", %{profile: p} do
    attrs = %{"label" => "Calcul mental", "description" => "Répondre par un nombre."}
    assert {:ok, settings} = SubjectQuestionTypes.add(p.id, "mathematiques", attrs)
    assert_receive {:format_inferred, "Calcul mental", "Répondre par un nombre."}
    type = List.last(settings.types)
    assert type["format"] == "definition"
    assert type["format_inferred"]
    assert {:ok, [^type]} = SubjectQuestionTypes.resolve(p.id, "mathematiques", [type["id"]])
    assert {:error, _} = SubjectQuestionTypes.add(p.id, "mathematiques", attrs)
    refute_receive {:format_inferred, _, _}
    assert SubjectQuestionTypes.formats([type]) == ["definition"]
  end

  test "old custom formats are inferred and cached on their first use", %{profile: p} do
    old = %{
      "id" => Ecto.UUID.generate(),
      "label" => "Calcul mental",
      "description" => "Un nombre.",
      "format" => "long"
    }

    Repo.insert!(%SubjectQuestionSettings{
      profile_id: p.id,
      subject: "mathematiques",
      types: [old]
    })

    assert {:ok, [updated]} = SubjectQuestionTypes.resolve(p.id, "mathematiques", [old["id"]])
    assert_receive {:format_inferred, "Calcul mental", "Un nombre."}
    assert updated["format"] == "definition"
    assert {:ok, [^updated]} = SubjectQuestionTypes.resolve(p.id, "mathematiques", [old["id"]])
    refute_receive {:format_inferred, _, _}
  end
end

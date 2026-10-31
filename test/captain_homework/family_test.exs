defmodule CaptainHomework.FamilyTest do
  use CaptainHomework.DataCase, async: false
  alias CaptainHomework.{Family, Repo, Study}
  import CaptainHomework.Fixtures

  setup do
    old = Application.fetch_env!(:captain_homework, :family_env)
    on_exit(fn -> Application.put_env(:captain_homework, :family_env, old) end)
    :ok
  end

  test "numbered names are normalized, sorted numerically, and blanks omitted" do
    members =
      Family.from_env(%{
        "HOMEWORK_CHILD_10_FIRST_NAME" => " Victor ",
        "HOMEWORK_CHILD_2_FIRST_NAME" => "E\u0301dgar",
        "HOMEWORK_CHILD_1_FIRST_NAME" => "  ",
        "HOMEWORK_CHILD_0_FIRST_NAME" => "Ignored",
        "UNRELATED" => "Ignored"
      })

    assert Enum.map(members, & &1.name) == ["Édgar", "Victor"]
  end

  test "Captain Notes theme variables override alternating defaults" do
    members =
      Family.from_env(%{
        "HOMEWORK_CHILD_1_FIRST_NAME" => "Alice",
        "HOMEWORK_CHILD_2_FIRST_NAME" => "Marius",
        "HOMEWORK_CHILD_3_FIRST_NAME" => "Bob",
        "PRONOTE_CHILD_1_THEME" => "green",
        "PRONOTE_CHILD_2_THEME" => "blue",
        "PRONOTE_CHILD_3_THEME" => "invalid"
      })

    assert Enum.map(members, & &1.theme) == ["green", "blue", "blue"]
  end

  test "invalid and oversized avatars fall back to initials" do
    for value <- ["invalid base64", Base.encode64("<svg></svg>"), String.duplicate("a", 262_145)] do
      assert [%{avatar: nil}] =
               Family.from_env(%{
                 "HOMEWORK_CHILD_1_FIRST_NAME" => "Alice",
                 "HOMEWORK_CHILD_1_AVATAR_BASE64" => value
               })
    end
  end

  test "existing profiles retain their lessons and identity across configuration changes" do
    existing = Repo.insert!(%Study.Profile{name: "Alice"})
    saved_lesson = lesson(existing)
    assert %{id: id} = profile()
    assert id == existing.id

    Application.put_env(:captain_homework, :family_env, %{
      "HOMEWORK_CHILD_1_FIRST_NAME" => "Alicia"
    })

    assert [%{id: ^id, name: "Alicia"}] = Study.profiles()
    assert Study.get_lesson!(id, saved_lesson.id).id == saved_lesson.id

    Application.put_env(:captain_homework, :family_env, %{})
    assert Study.profiles() == []
    assert Study.get_profile(id) == nil
    assert Repo.get!(Study.Profile, id)

    Application.put_env(:captain_homework, :family_env, %{
      "HOMEWORK_CHILD_1_FIRST_NAME" => "Alicia"
    })

    assert [%{id: ^id}] = Study.profiles()
  end

  test "repeated synchronization does not create duplicate profiles" do
    first = Study.profiles()
    assert Study.profiles() == first
    assert Repo.aggregate(Study.Profile, :count) == length(first)
  end

  test "ambiguous legacy profiles are not silently linked" do
    Repo.insert!(%Study.Profile{name: "Alice"})
    Repo.insert!(%Study.Profile{name: "alice"})
    assert_raise RuntimeError, ~r/Multiple existing profiles/, fn -> Study.profiles() end
  end
end

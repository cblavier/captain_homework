defmodule CaptainHomework.AccountsTest do
  use CaptainHomework.DataCase, async: false
  alias CaptainHomework.Accounts

  test "imports Notes PINs without needing Pronote credentials, preserving numbered mapping" do
    accounts =
      Accounts.from_env(%{
        "PRONOTE_FAMILY_PIN_CODE" => "12345678",
        "PRONOTE_CHILD_2_FIRST_NAME" => "Victor",
        "PRONOTE_CHILD_2_PIN_CODE" => "23456789",
        "PRONOTE_PARENT_1_FIRST_NAME" => "Agnès",
        "PRONOTE_PARENT_1_PIN_CODE" => "34567890"
      })

    assert Enum.map(accounts, & &1.id) == ["family", "child-2", "parent-1"]
    assert Enum.at(accounts, 1).profile_key == "HOMEWORK_CHILD_2"
    assert Enum.at(accounts, 2).label == "Agnès"
  end

  test "public metadata contains no PINs and unmapped children get no profile" do
    refute Enum.any?(Accounts.all(), &Map.has_key?(&1, :pin))
    assert Accounts.profiles(%{role: :child, profile_key: "HOMEWORK_CHILD_999"}) == []
    assert Accounts.profiles(nil) == []
  end
end

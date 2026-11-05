defmodule CaptainHomework.TextTest do
  use ExUnit.Case, async: true
  alias CaptainHomework.Text

  test "French count labels agree for zero, one and multiple items" do
    for {singular, plural} <- [
          {"type de question", "types de questions"},
          {"contrôle", "contrôles"},
          {"question prête", "questions prêtes"},
          {"réponse", "réponses"},
          {"page", "pages"}
        ] do
      assert Text.count_label(0, singular, plural) == "0 #{singular}"
      assert Text.count_label(1, singular, plural) == "1 #{singular}"
      assert Text.count_label(2, singular, plural) == "2 #{plural}"
      assert Text.count_label(31, singular, plural) == "31 #{plural}"
    end
  end

  test "fractional points below two use the singular" do
    assert Text.plural(0.5, "point", "points") == "point"
    assert Text.plural(1.5, "point", "points") == "point"
    assert Text.plural(2.5, "point", "points") == "points"
  end
end

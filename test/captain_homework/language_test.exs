defmodule CaptainHomework.LanguageTest do
  use ExUnit.Case, async: true
  alias CaptainHomework.Exams.Language

  defp error(attrs \\ %{}) do
    Map.merge(
      %{
        "field" => "",
        "original" => "chat",
        "replacement" => "chats",
        "occurrence" => 1,
        "explanation" => "Après « les », le nom est au pluriel."
      },
      attrs
    )
  end

  test "exact Unicode excerpts and repeated occurrences preserve the original response" do
    text = "Élodie voit un chat. Les chat jouent."
    [correction] = Language.validate(text, [error(%{"occurrence" => 2})])
    [row] = Language.rows(text, [correction])
    assert Enum.map_join(row.segments, & &1.text) == text
    assert Enum.find(row.segments, & &1.error).error["replacement"] == "chats"
    assert hd(row.segments).text == "Élodie voit un chat. Les "
  end

  test "invalid and overlapping model annotations are discarded without altering text" do
    errors = [
      error(),
      error(),
      error(%{"original" => "absent"}),
      error(%{"occurrence" => 0}),
      error(%{"field" => "unknown"}),
      %{"original" => ""}
    ]

    assert length(Language.validate("Les chat jouent.", errors)) == 1
    assert Language.validate("Les chats jouent.", nil) == []
  end

  test "slot corrections remain attached to the correct field" do
    answers = %{"1" => "chat", "2" => "chat"}
    errors = Language.validate(answers, [error(%{"field" => "2"})])
    [first, second] = Language.rows(answers, errors)
    refute Enum.any?(first.segments, & &1.error)
    assert Enum.any?(second.segments, & &1.error)
  end
end

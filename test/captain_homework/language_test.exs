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

  test "unique contextual Unicode excerpts preserve the original response" do
    text = "Élodie voit un chat. Les chat jouent."

    [correction] =
      Language.validate(text, [error(%{"original" => "Les chat", "replacement" => "Les chats"})])

    [row] = Language.rows(text, [correction])
    assert Enum.map_join(row.segments, & &1.text) == text
    assert Enum.find(row.segments, & &1.error).error["replacement"] == "Les chats"
    assert hd(row.segments).text == "Élodie voit un chat. "
  end

  test "repeated words require context instead of trusting the model occurrence" do
    text = "2 droites peuvent êtres prolongées sans besoin de les prolongées."
    ambiguous = error(%{"original" => "prolongées", "replacement" => "prolonger"})

    assert Language.validate(text, [ambiguous]) == []
    assert Language.validate(text, [Map.put(ambiguous, "occurrence", 2)]) == []

    contextual = %{
      ambiguous
      | "original" => "de les prolongées",
        "replacement" => "de les prolonger"
    }

    [correction] = Language.validate(text, [contextual])
    [row] = Language.rows(text, [correction])
    assert hd(row.segments).text == "2 droites peuvent êtres prolongées sans besoin "
    assert Enum.map_join(row.segments, & &1.text) == text
    assert Enum.find(row.segments, & &1.error).error["replacement"] == "de les prolonger"
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

  test "rejects expansions that duplicate the surrounding words, including Unicode" do
    for {answer, original, replacement} <- [
          {"être coupé des flux mondiaux", "être", "être coupé"},
          {"être coupé des flux mondiaux", "des flux", "coupé des flux"},
          {"être coupé des flux mondiaux", "être", "être coupé des flux"},
          {"une école très connue", "une", "une école"}
        ] do
      assert Language.validate(answer, [
               error(%{"original" => original, "replacement" => replacement})
             ]) == []
    end
  end

  test "preserves genuine agreements, conjugations, accents, insertions and existing repetitions" do
    for {answer, original, replacement} <- [
          {"les chat jouent", "chat", "chats"},
          {"ils joue", "joue", "jouent"},
          {"une ecole", "ecole", "école"},
          {"une école", "une", "une grande"},
          {"nous sommes lavés", "nous sommes", "nous nous sommes"},
          {"les chat très très petits", "chat", "chats"}
        ] do
      assert [_] =
               Language.validate(answer, [
                 error(%{"original" => original, "replacement" => replacement})
               ])
    end
  end

  test "saved duplicate corrections are hidden without shifting the remaining explanation indices" do
    answer = "être coupé des flux mondiau"

    old_error = %{
      "field" => "",
      "original" => "être",
      "replacement" => "être coupé",
      "explanation" => "Ancienne correction incorrecte.",
      "start" => 0,
      "length" => 5
    }

    [valid_error] =
      Language.validate(answer, [error(%{"original" => "mondiau", "replacement" => "mondiaux"})])

    [row] = Language.rows(answer, [old_error, valid_error])
    assert Enum.map_join(row.segments, & &1.text) == answer

    assert [%{text: "mondiau", replacement: "mondiaux", index: 1}] =
             Enum.filter(row.segments, & &1.error)
  end

  test "only changed words and punctuation are highlighted, retaining the original and corrected text" do
    for {answer, replacement, highlighted} <- [
          {"une ville", "Une ville", [{"une", "Une"}]},
          {"partent où on manque d'emplois", "partent, où on manque d'emplois", [{"", ","}]},
          {"les chat joue", "les chats jouent", [{"chat", "chats"}, {"joue", "jouent"}]},
          {"très, pauvre", "très pauvre", [{",", ""}]},
          {"une ecole", "une école", [{"ecole", "école"}]}
        ] do
      errors =
        Language.validate(answer, [error(%{"original" => answer, "replacement" => replacement})])

      [row] = Language.rows(answer, errors)
      assert Enum.map_join(row.segments, & &1.text) == answer

      assert Enum.map_join(row.segments, fn s -> if s.error, do: s.replacement, else: s.text end) ==
               replacement

      assert Enum.map(Enum.filter(row.segments, & &1.error), &{&1.text, &1.replacement}) ==
               highlighted
    end
  end
end

defmodule CaptainHomework.SymbolsTest do
  use ExUnit.Case, async: true
  alias CaptainHomework.Symbols

  test "suggestions preserve alternatives and never use answers or hidden source text" do
    question = %{
      "prompt" => "Complète avec ∈ ou ∉.",
      "text" => "D ... (AB)",
      "answer" => "Ω",
      "images" => [%{"source_page_id" => "shown"}]
    }

    pages = [%{id: "shown", text: "Droites ∥ et ⊥"}, %{id: "hidden", text: "π"}]

    symbols =
      question |> Symbols.context(pages) |> Symbols.suggestions() |> Enum.map(&elem(&1, 0))

    assert symbols == ["∈", "∉", "∥", "⊥"]

    assert Symbols.suggestions("Utilise ∉") == [
             {"∈", "Appartient à"},
             {"∉", "N’appartient pas à"}
           ]

    assert Symbols.context(%{"answer" => "∉", "rubric" => "∈"}) == ""
  end

  test "common characters and languages are always available without suggestions" do
    assert Symbols.suggestions("Écris ta réponse.") == []
    [{"usual", _, common}, {"math", _, _}, {"languages", _, languages}] = Symbols.families()

    assert Enum.all?(~w"[ ] ( ) { } « »", fn symbol ->
             Enum.any?(common, &(elem(&1, 0) == symbol))
           end)

    assert {"ñ", "N tilde"} in languages
  end
end

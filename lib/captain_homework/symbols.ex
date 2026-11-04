defmodule CaptainHomework.Symbols do
  @moduledoc "Shared input characters. Suggestions use exercise content, never its answer."

  @families [
    {"usual", "Courants",
     [
       {"[", "Crochet ouvrant"},
       {"]", "Crochet fermant"},
       {"(", "Parenthèse ouvrante"},
       {")", "Parenthèse fermante"},
       {"{", "Accolade ouvrante"},
       {"}", "Accolade fermante"},
       {"«", "Guillemet ouvrant"},
       {"»", "Guillemet fermant"},
       {"…", "Points de suspension"},
       {"—", "Tiret long"}
     ]},
    {"math", "Maths",
     [
       {"+", "Plus"},
       {"−", "Moins"},
       {"×", "Multiplié par"},
       {"÷", "Divisé par"},
       {"=", "Égal"},
       {"≠", "Différent de"},
       {"<", "Inférieur à"},
       {">", "Supérieur à"},
       {"≤", "Inférieur ou égal"},
       {"≥", "Supérieur ou égal"},
       {"∈", "Appartient à"},
       {"∉", "N’appartient pas à"},
       {"∥", "Parallèle à"},
       {"⊥", "Perpendiculaire à"},
       {"°", "Degré"},
       {"²", "Au carré"},
       {"³", "Au cube"},
       {"√", "Racine carrée"},
       {"π", "Pi"},
       {"α", "Alpha"},
       {"β", "Bêta"},
       {"γ", "Gamma"},
       {"Δ", "Delta"},
       {"Ω", "Oméga"}
     ]},
    {"languages", "Langues",
     [
       {"é", "E accent aigu"},
       {"è", "E accent grave"},
       {"ê", "E accent circonflexe"},
       {"à", "A accent grave"},
       {"ç", "C cédille"},
       {"œ", "O E liés"},
       {"É", "E majuscule accent aigu"},
       {"À", "A majuscule accent grave"},
       {"á", "A accent aigu"},
       {"í", "I accent aigu"},
       {"ó", "O accent aigu"},
       {"ú", "U accent aigu"},
       {"ñ", "N tilde"},
       {"ü", "U tréma"},
       {"¿", "Point d’interrogation inversé"},
       {"¡", "Point d’exclamation inversé"},
       {"ß", "Eszett"}
     ]}
  ]
  @suggestion_groups [~w(∈ ∉), ~w(< > ≤ ≥), ~w(= ≠), ~w(∥ ⊥), ~w(× ÷), ~w(² ³ √), ~w(π α β γ Δ Ω)]

  def families, do: @families

  def suggestions(context) when is_binary(context) do
    symbols =
      @suggestion_groups
      |> Enum.filter(fn group -> Enum.any?(group, &String.contains?(context, &1)) end)
      |> List.flatten()
      |> Enum.take(8)

    labels = @families |> Enum.flat_map(&elem(&1, 2)) |> Map.new()
    Enum.map(symbols, &{&1, Map.fetch!(labels, &1)})
  end

  def context(question, pages \\ []) do
    image_ids = Enum.map(Map.get(question, "images", []), & &1["source_page_id"])

    image_text =
      pages
      |> Enum.filter(&(&1.id in image_ids))
      |> Enum.map(& &1.text)

    [question["prompt"], question["text"] | image_text]
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
  end
end

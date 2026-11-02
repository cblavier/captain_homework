defmodule CaptainHomework.Exams.Constraints do
  @moduledoc "Jointly feasible targets for response effort and resolution mode."
  @efforts ~w(direct short developed)
  @definitions """
  direct : choisir, nommer, recopier, citer une liste, compléter des trous ou classer des numéros.
  Demander « écris une phrase » pour relever une date, un rôle ou reformuler une définition reste direct.
  Restituer une définition ou énumérer des faits mémorisés reste direct, même si le barème exige
  plusieurs fragments factuels. Définir la Préhistoire par ses deux bornes reste direct : ce n'est
  ni une petite explication ni une rédaction développée. Le nombre de faits ne détermine pas l'effort.
  short : une seule petite explication ou déduction en 1 ou 2 phrases, avec UNE SEULE raison
  obligatoire. La consigne doit demander cette raison. Une conclusion accompagnée de deux indices
  ou justifications obligatoires dépasse short. Pour document + short, la conclusion doit être
  réellement déduite du support, pas déjà écrite mot pour mot : relever ou paraphraser un passage
  reste direct, même si la consigne emploie « explique » ou « déduis ».
  developed : une réponse structurée de 3 à 5 phrases, avec au moins DEUX aspects ou raisons
  distincts EXPLIQUÉS. La consigne doit demander explicitement cette longueur et ces explications.
  Une simple liste de faits ou les deux bornes d'une définition ne suffit jamais à cette catégorie.
  Ces mêmes critères s'appliquent à la rédaction et à l'audit : consigne, réponse modèle et barème
  doivent imposer le même travail, sans raison supplémentaire cachée dans le corrigé.
  Compte uniquement les éléments obligatoires du barème, pas les alternatives acceptables.
  knowledge : mobiliser les connaissances apprises dans les leçons, sans réponse fournie dans le contrôle.
  document : lire, analyser ou déduire à partir d'un support affiché, même s'il provient d'une leçon.
  Un QCM de connaissances reste knowledge quand ses propres options contiennent la bonne réponse
  parmi des distracteurs sans la désigner : ces choix ne sont ni un document ni une fuite de réponse.
  Les indices de la consigne et de la phrase à trous sont nécessaires à la question : ils ne révèlent
  pas la réponse simplement parce qu'ils permettent de choisir un mot appris. Il y a fuite si la
  bonne option est désignée, si une banque de réponses résout un trou de connaissances, ou si un
  texte, une image ou une autre question donne l'information attendue et court-circuite le rappel du cours.
  """
  def definitions, do: @definitions

  def targets(count, types, pages \\ nil) do
    course? = is_nil(pages) or Enum.any?(pages, &(Map.get(&1, :kind) == "lesson"))
    documents? = is_nil(pages) or Enum.any?(pages, &(Map.get(&1, :kind) == "resource"))
    desired = rounded(count, [4, 4, 2])

    target_knowledge =
      if(course?, do: if(documents?, do: div(count + 1, 2), else: count), else: 0)

    cells = cells(types, course?)

    candidates =
      for direct <- 0..count,
          short <- 0..(count - direct),
          counts = [direct, short, count - direct - short],
          Enum.all?(Enum.zip(@efforts, counts), fn {effort, n} ->
            n == 0 or Enum.any?(cells, fn {e, _} -> e == effort end)
          end) do
        minimum =
          Enum.zip(@efforts, counts)
          |> Enum.reduce(0, fn {e, n}, acc ->
            if {e, "document"} in cells, do: acc, else: acc + n
          end)

        maximum =
          Enum.zip(@efforts, counts)
          |> Enum.reduce(0, fn {e, n}, acc ->
            if {e, "knowledge"} in cells, do: acc + n, else: acc
          end)

        knowledge = target_knowledge |> max(minimum) |> min(maximum)

        error =
          Enum.zip(counts, desired) |> Enum.map(fn {a, b} -> (a - b) * (a - b) end) |> Enum.sum()

        score = error + 2 * (knowledge - target_knowledge) * (knowledge - target_knowledge)
        {score, abs(knowledge - target_knowledge), Enum.at(counts, 2), counts, knowledge}
      end

    {_, _, _, counts, knowledge} = Enum.min(candidates)

    %{
      effort: Map.new(Enum.zip(@efforts, counts)),
      basis: %{"knowledge" => knowledge, "document" => count - knowledge}
    }
  end

  def compatible?(type, effort, basis, pages) do
    course? = Enum.any?(pages, &(Map.get(&1, :kind) == "lesson"))
    {effort, basis} in cells([type], course?)
  end

  def slots(count, types, pages, kept \\ []) do
    targets = targets(count, types, pages)
    course? = Enum.any?(pages, &(Map.get(&1, :kind) == "lesson"))
    available = cells(types, course?)

    efforts = Enum.flat_map(@efforts, &List.duplicate(&1, targets.effort[&1]))
    forced = Enum.count(efforts, &({&1, "document"} not in available))

    {slots, 0} =
      Enum.map_reduce(efforts, targets.basis["knowledge"] - forced, fn effort, remaining ->
        cond do
          {effort, "document"} not in available ->
            {{effort, "knowledge"}, remaining}

          remaining > 0 and {effort, "knowledge"} in available ->
            {{effort, "knowledge"}, remaining - 1}

          true ->
            {{effort, "document"}, remaining}
        end
      end)

    kept_ids = Enum.map(kept, & &1["plan_id"])

    new_ids =
      Stream.iterate(1, &(&1 + 1))
      |> Stream.map(&"q#{&1}")
      |> Stream.reject(&(&1 in kept_ids))
      |> Enum.take(max(count - length(kept_ids), 0))

    slots
    |> Enum.sort_by(fn {effort, basis} ->
      {if(basis == "knowledge", do: 0, else: 1), Enum.find_index(@efforts, &(&1 == effort))}
    end)
    |> Enum.zip(kept_ids ++ new_ids)
    |> Enum.map(fn {{effort, basis}, id} ->
      %{
        "id" => id,
        "response_effort" => effort,
        "answer_basis" => basis,
        "allowed_types" => Enum.filter(types, &compatible?(&1, effort, basis, pages))
      }
    end)
  end

  def validate_slots(_questions, nil), do: :ok

  def validate_slots(questions, slots) do
    expected = Map.new(slots, &{&1["id"], &1})

    issues =
      Enum.flat_map(questions, fn q ->
        case expected[q["id"]] do
          nil ->
            ["Identifiant absent de la grille prévue : #{q["id"]}."]

          slot ->
            if q["response_effort"] == slot["response_effort"] and
                 q["answer_basis"] == slot["answer_basis"] and q["type"] in slot["allowed_types"],
               do: [],
               else: ["Question #{q["id"]} : respecte la case prévue #{Jason.encode!(slot)}."]
        end
      end)

    if issues == [], do: :ok, else: {:error, Enum.join(issues, " ")}
  end

  defp cells(types, course?) do
    types
    |> Enum.flat_map(fn
      "reading" ->
        Enum.map(@efforts, &{&1, "document"})

      "long" ->
        for e <- @efforts, b <- ~w(knowledge document), do: {e, b}

      type when type in ~w(definition mcq cloze diagram) ->
        [{"direct", "knowledge"}, {"direct", "document"}]

      _ ->
        []
    end)
    |> Enum.uniq()
    |> Enum.reject(fn {_, b} -> b == "knowledge" and not course? end)
  end

  defp rounded(count, weights) do
    base = Enum.map(weights, &div(count * &1, 10))
    rest = count - Enum.sum(base)

    extras =
      weights
      |> Enum.with_index()
      |> Enum.sort_by(fn {w, i} -> {-rem(count * w, 10), i} end)
      |> Enum.take(rest)
      |> MapSet.new(fn {_, i} -> i end)

    base
    |> Enum.with_index()
    |> Enum.map(fn {n, i} -> n + if(MapSet.member?(extras, i), do: 1, else: 0) end)
  end
end

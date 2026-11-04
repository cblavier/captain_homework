defmodule CaptainHomework.Exams.Constraints do
  @moduledoc "Supported combinations of response format, effort and resolution mode."
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
  Pour photo, developed désigne une construction graphique en plusieurs étapes, sans exiger de rédaction.
  knowledge : mobiliser les connaissances apprises dans les leçons, sans réponse fournie dans le contrôle.
  document : lire, analyser ou déduire à partir d'un support affiché, même s'il provient d'une leçon.
  Un QCM de connaissances reste knowledge quand ses propres options contiennent la bonne réponse
  parmi des distracteurs sans la désigner : ces choix ne sont ni un document ni une fuite de réponse.
  Les indices de la consigne et de la phrase à trous sont nécessaires à la question : ils ne révèlent
  pas la réponse simplement parce qu'ils permettent de choisir un mot appris. Il y a fuite si la
  bonne option est désignée, si une banque de réponses résout un trou de connaissances, ou si un
  texte, une image ou une autre question donne l'information attendue et court-circuite le rappel du cours.

  PERTINENCE PÉDAGOGIQUE : même direct, chaque exercice doit mobiliser une connaissance ou une
  compétence du cours. Une réponse courte peut être pertinente ; allonger la réponse ne rend pas
  une tâche plus utile. Écarte les questions résolubles par le seul repérage de lettres, la longueur
  d'un mot ou un indice de forme dans les options, sans comprendre ni rappeler la notion évaluée.
  Par exemple, « Quel mot commence par spi ? » avec spoon, spider, speaker, spring ne vérifie
  aucune connaissance du vocabulaire anglais : remplace cette tâche par le sens du mot, sa
  traduction ou son emploi dans une phrase contextualisée, à partir du vocabulaire enseigné.
  Les distracteurs d'un QCM doivent être plausibles pour la compétence visée, de même nature et
  sans indice superficiel qui désigne la réponse. La reconnaissance de lettres ou de sons reste
  pertinente si cette compétence est explicitement enseignée et constitue l'objectif du cours.
  Pour un document, relever une information reste valide quand cela vérifie sa compréhension.
  """
  def definitions, do: @definitions

  def effort_supported?(type, effort),
    do: Enum.any?(cells([type], true), fn {supported, _} -> supported == effort end)

  def compatible?(type, effort, basis, pages) do
    course? = Enum.any?(pages, &(Map.get(&1, :kind) == "lesson"))
    {effort, basis} in cells([type], course?)
  end

  defp cells(types, course?) do
    types
    |> Enum.flat_map(fn
      "listening" ->
        [{"direct", "document"}]

      "reading" ->
        Enum.map(@efforts, &{&1, "document"})

      "photo" ->
        [{"developed", "knowledge"}, {"developed", "document"}]

      "long" ->
        for e <- @efforts, b <- ~w(knowledge document), do: {e, b}

      type when type in ~w(definition mcq cloze diagram ordering) ->
        [{"direct", "knowledge"}, {"direct", "document"}]

      _ ->
        []
    end)
    |> Enum.uniq()
    |> Enum.reject(fn {_, b} -> b == "knowledge" and not course? end)
  end
end

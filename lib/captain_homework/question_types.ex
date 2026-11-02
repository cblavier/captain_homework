defmodule CaptainHomework.QuestionTypes do
  @options [
    {"definition", "Définition", "Donner un mot ou une définition."},
    {"mcq", "QCM", "Choisir une réponse parmi plusieurs propositions."},
    {"cloze", "Texte à trous", "Compléter les mots manquants."},
    {"reading", "Compréhension de texte", "Répondre à partir d’un texte fourni."},
    {"long", "Réponse rédigée", "Expliquer, justifier ou remettre des événements dans l’ordre."},
    {"diagram", "Schéma à compléter", "Nommer les éléments repérés sur un schéma."}
  ]
  def options, do: @options
  def ids, do: Enum.map(@options, &elem(&1, 0))
  def valid?(types), do: is_list(types) and types != [] and Enum.all?(types, &(&1 in ids()))
end

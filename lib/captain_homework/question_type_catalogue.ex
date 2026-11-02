defmodule CaptainHomework.QuestionTypeCatalogue do
  @moduledoc "Catalogue initial par matière, installé explicitement en développement."
  @definitions %{
    "mcq" => {"QCM", "mcq", "Choisir une réponse parmi plusieurs propositions."},
    "vrai-faux" => {"Vrai/faux", "mcq", "Indiquer si une affirmation est vraie ou fausse."},
    "definition" => {"Définition", "definition", "Donner un mot ou une définition brève."},
    "cloze" => {"Texte à trous", "cloze", "Compléter les mots ou valeurs manquants."},
    "association" =>
      {"Association", "cloze", "Associer les éléments de deux listes explicitement fournies."},
    "conjugaison" =>
      {"Conjugaison", "cloze",
       "Compléter des formes verbales selon la personne et le temps demandés."},
    "traduction" => {"Traduction", "long", "Traduire le passage fourni dans la langue demandée."},
    "reading" =>
      {"Compréhension de texte", "reading",
       "Lire un texte fourni et répondre aux questions qui portent sur son contenu."},
    "expression-ecrite" =>
      {"Expression écrite", "long",
       "Rédiger un court texte dans la langue étudiée à partir d’une consigne."},
    "analyse-grammaticale" =>
      {"Analyse grammaticale", "long",
       "Identifier et expliquer les éléments grammaticaux d’une phrase fournie."},
    "reecriture" =>
      {"Réécriture", "long", "Réécrire un passage en respectant les transformations demandées."},
    "redaction" =>
      {"Rédaction", "long", "Rédiger une réponse organisée répondant à la consigne."},
    "chronologie" =>
      {"Classement chronologique", "long",
       "Remettre dans l’ordre chronologique les événements explicitement fournis."},
    "carte" =>
      {"Carte à compléter", "diagram",
       "Compléter les repères numérotés d’une carte lisible fournie dans la question."},
    "explication" =>
      {"Réponse courte expliquée", "long",
       "Répondre en une ou deux phrases avec une explication brève."},
    "analyse-document" =>
      {"Analyse de document", "reading",
       "Analyser un document fourni et justifier la réponse avec ses informations."},
    "calcul-direct" =>
      {"Calcul direct", "definition", "Effectuer un calcul simple et donner son résultat."},
    "calcul-detaille" =>
      {"Calcul détaillé", "long", "Effectuer un calcul en présentant les étapes utiles."},
    "application" =>
      {"Exercice d’application", "long", "Appliquer une méthode du cours à une situation donnée."},
    "lecture-donnees" =>
      {"Lecture de graphique ou tableau", "reading",
       "Lire et interpréter les informations d’un graphique ou tableau fourni."},
    "probleme" =>
      {"Problème", "long",
       "Résoudre une situation en plusieurs étapes en présentant le raisonnement."},
    "demonstration" =>
      {"Démonstration", "long",
       "Justifier une propriété en construisant un raisonnement à partir des données et du cours."},
    "diagram" =>
      {"Schéma à compléter", "diagram",
       "Nommer les éléments numérotés d’un véritable schéma fourni."},
    "experience" =>
      {"Analyse d’expérience", "reading",
       "Interpréter un protocole et des résultats fournis pour en tirer une conclusion."},
    "classement" =>
      {"Classement", "long", "Classer les éléments fournis selon les critères demandés."},
    "programmation" =>
      {"Programmation", "long",
       "Compléter, écrire ou corriger un court programme à partir des consignes fournies."}
  }
  @subjects %{
    "anglais" => [
      {"mcq", "quick"},
      {"vrai-faux", "quick"},
      {"cloze", "medium"},
      {"association", "medium"},
      {"conjugaison", "medium"},
      {"traduction", "medium"},
      {"reading", "long"},
      {"expression-ecrite", "long"}
    ],
    "espagnol" => [
      {"mcq", "quick"},
      {"vrai-faux", "quick"},
      {"cloze", "medium"},
      {"association", "medium"},
      {"conjugaison", "medium"},
      {"traduction", "medium"},
      {"reading", "long"},
      {"expression-ecrite", "long"}
    ],
    "francais" => [
      {"mcq", "quick"},
      {"definition", "quick"},
      {"conjugaison", "medium"},
      {"analyse-grammaticale", "medium"},
      {"reecriture", "medium"},
      {"reading", "long"},
      {"redaction", "long"}
    ],
    "histoire-geo" => [
      {"mcq", "quick"},
      {"vrai-faux", "quick"},
      {"definition", "quick"},
      {"chronologie", "medium"},
      {"carte", "medium"},
      {"explication", "medium"},
      {"analyse-document", "long"},
      {"redaction", "long"}
    ],
    "latin" => [
      {"mcq", "quick"},
      {"definition", "quick"},
      {"cloze", "medium"},
      {"conjugaison", "medium"},
      {"analyse-grammaticale", "medium"},
      {"traduction", "long"},
      {"reading", "long"}
    ],
    "mathematiques" => [
      {"mcq", "quick"},
      {"vrai-faux", "quick"},
      {"calcul-direct", "quick"},
      {"calcul-detaille", "medium"},
      {"application", "medium"},
      {"lecture-donnees", "medium"},
      {"probleme", "long"},
      {"demonstration", "long"}
    ],
    "physique-chimie" => [
      {"mcq", "quick"},
      {"vrai-faux", "quick"},
      {"definition", "quick"},
      {"application", "medium"},
      {"diagram", "medium"},
      {"lecture-donnees", "medium"},
      {"probleme", "long"},
      {"experience", "long"},
      {"analyse-document", "long"}
    ],
    "svt" => [
      {"mcq", "quick"},
      {"vrai-faux", "quick"},
      {"definition", "quick"},
      {"diagram", "medium"},
      {"classement", "medium"},
      {"explication", "medium"},
      {"analyse-document", "long"},
      {"experience", "long"}
    ],
    "technologie" => [
      {"mcq", "quick"},
      {"vrai-faux", "quick"},
      {"definition", "quick"},
      {"association", "medium"},
      {"diagram", "medium"},
      {"application", "medium"},
      {"analyse-document", "long"},
      {"probleme", "long"},
      {"programmation", "long"}
    ]
  }

  def for_subject(subject) do
    @subjects
    |> Map.fetch!(subject)
    |> Enum.map(fn {key, duration} ->
      {label, format, description} = Map.fetch!(@definitions, key)

      %{
        "id" =>
          if(key in CaptainHomework.QuestionTypes.ids(), do: key, else: "catalogue-" <> key),
        "label" => label,
        "description" => description,
        "format" => format,
        "format_inferred" => true,
        "work_duration" => duration
      }
    end)
  end
end

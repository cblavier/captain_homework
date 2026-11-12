defmodule CaptainHomework.Exams.Pronunciation do
  @moduledoc false

  def instructions do
    """
    Pour pronunciation, l’élève lit à voix haute le champ text et enregistre sa voix.
    Fournis une courte phrase de 3 à 25 mots en anglais ou espagnol, issue du vocabulaire du cours.
    prompt est « Lis à voix haute le texte suivant. » sauf consigne fixe définie par le type.
    answer contient le texte à prononcer, rubric évalue uniquement les sons, l’accentuation
    et l’intelligibilité adaptés au niveau, sans exiger un accent natif. Ce texte visible est
    indispensable à la lecture : ce n’est pas une fuite de réponse ni une tâche de rappel.
    answer_basis=document, response_effort=direct, support_id="", audio_script=null,
    options=[], slots=[], diagram=null, image_ids=[]. Même règle en classique et en flashcard.
    """
  end

  def errors(%{"type" => "pronunciation"} = question) do
    text = question["text"]

    if is_binary(text) and length(String.split(text)) in 3..25 and
         question["answer_basis"] in [nil, "document"] and
         question["response_effort"] in [nil, "direct"] and question["support_id"] in [nil, ""],
       do: [],
       else: ["Prononciation : fournis une phrase à lire de 3 à 25 mots, sans support partagé."]
  end

  def errors(_), do: []
end

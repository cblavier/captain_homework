defmodule CaptainHomework.Exams.VisibleSupport do
  @moduledoc "Validates student-visible dependencies independently of the model's verdict."

  def present?(question) do
    Enum.any?(~w(text support_text), &text?(question[&1])) or
      Enum.any?(~w(images image_ids), &nonempty_list?(question[&1])) or
      (question["type"] == "ordering" and nonempty_list?(question["options"])) or
      (question["type"] == "diagram" and is_map(question["diagram"])) or
      CaptainHomework.Exams.Listening.valid_script?(question["audio_script"])
  end

  def errors(question) do
    prompt = question["prompt"] || question["task"] || ""

    reference? =
      Regex.match?(
        ~r/\b(?:document|doc\.?|texte|tableau|image|illustration|carte|graphique|schéma|figure|passage|extrait)\s*(?:n[°ºo]\s*)?\d+\b/iu,
        prompt
      ) or
        (Regex.match?(
           ~r/\b(?:ci[- ]dessous|ci[- ]dessus|ci[- ]contre|joint[e]?|suivant[e]?)\b/iu,
           prompt
         ) and
           Regex.match?(
             ~r/\b(?:document|texte|tableau|image|illustration|carte|graphique|schéma|figure|passage|extrait)\b/iu,
             prompt
           )) or
        Regex.match?(
          ~r/\b(?:à partir|à l[’']aide|d[’']après|en utilisant)\s+(?:du|le|la|l[’']|ce|cet|cette)\s*(?:document|texte|tableau|image|carte|graphique|schéma|extrait)\b/iu,
          prompt
        )

    if not present?(question) and (question["answer_basis"] == "document" or reference?) do
      [
        "Support absent : cette question dépend d’un document qui n’est pas accessible à l’élève. Respecte le type : s’il interdit le contenu, choisis une question autonome fondée sur le cours, éventuellement sur une autre notion. Une reformulation de la référence ne suffit pas."
      ]
    else
      []
    end
  end

  defp text?(value), do: is_binary(value) and String.trim(value) != ""
  defp nonempty_list?(value), do: is_list(value) and value != []
end

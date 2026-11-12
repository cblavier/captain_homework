defmodule CaptainHomeworkWeb.SharedExamMetadata do
  alias CaptainHomework.Study

  def title(exam, mode) do
    subject = Study.subject_with_preposition(Study.subject!(exam.lesson.subject))
    kind = if mode == "correction", do: "Corrigé de l’évaluation", else: "Évaluation"
    "#{kind} #{subject} — #{exam.lesson.title}"
  end

  def build(share) do
    %{
      title: title(share.exam, share.mode) <> " | Captain Homework",
      description:
        if(share.mode == "correction",
          do:
            "Consultez les réponses et les explications de cette évaluation corrigée sur Captain Homework.",
          else:
            "À vous de jouer ! Complétez cette évaluation à votre rythme et découvrez votre correction sur Captain Homework."
        )
    }
  end
end

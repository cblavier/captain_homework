defmodule CaptainHomework.Fixtures do
  alias CaptainHomework.{Study, Repo}

  def profile(name \\ "Alice") do
    Enum.find(Study.profiles(), &(&1.name == name)) || raise "Unconfigured test profile: #{name}"
  end

  def lesson(profile, subject \\ "svt") do
    {:ok, lesson} = Study.create_lesson(profile, %{"title" => "La cellule", "subject" => subject})
    lesson
  end

  def page(lesson) do
    {:ok, page} =
      Study.add_page(lesson, %{
        filename: "cours.png",
        storage_key: "test.png",
        content_type: "image/png",
        text: "La cellule contient un noyau, un cytoplasme et une membrane.",
        status: "ready"
      })

    page
  end

  def question(id \\ "q1", type \\ "long") do
    %{
      "id" => id,
      "origin_id" => id,
      "type" => type,
      "prompt" => "Explique le rôle de la membrane.",
      "text" => "",
      "options" => [],
      "slots" => [],
      "diagram" => nil,
      "answer" => "Elle délimite la cellule.",
      "rubric" => "Délimitation de la cellule",
      "points" => 4
    }
  end

  def exam(lesson, questions \\ [question()]) do
    Repo.insert!(%Study.Exam{
      lesson_id: lesson.id,
      questions: questions,
      instructions: "Instructions SVT"
    })
  end
end

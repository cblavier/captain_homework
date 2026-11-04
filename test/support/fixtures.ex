defmodule CaptainHomework.Fixtures do
  alias CaptainHomework.{Study, Repo}

  def profile(name \\ "Alice") do
    Enum.find(Study.profiles(), &(&1.name == name)) || raise "Unconfigured test profile: #{name}"
  end

  def lesson(profile, subject \\ "svt") do
    ensure_question_definitions()
    {:ok, lesson} = Study.create_lesson(profile, %{"title" => "La cellule", "subject" => subject})
    lesson
  end

  def ensure_question_definitions do
    if CaptainHomework.QuestionDefinitions.list() == [] do
      for {format, response, content} <- [
            {"definition", "short_text", "text"},
            {"mcq", "single_choice", "text"},
            {"cloze", "cloze", "text"},
            {"reading", "long_text", "document"},
            {"long", "long_text", "text"},
            {"diagram", "legends", "image"}
          ] do
        {:ok, _} =
          CaptainHomework.QuestionDefinitions.save(%Study.QuestionDefinition{}, %{
            name: "Test #{format}",
            subjects: Enum.map(Study.subjects(), & &1.id),
            modes:
              if(format in ["definition", "mcq"], do: ["classic", "flashcard"], else: ["classic"]),
            response_kind: response,
            instruction_kind: "dynamic",
            content_kind: content,
            content_presence: "optional",
            work_duration: "quick"
          })
      end
    end
  end

  def question_type_ids(formats) do
    Enum.map(formats, fn format ->
      CaptainHomework.QuestionDefinitions.list()
      |> Enum.find(&(CaptainHomework.QuestionDefinitions.engine_format(&1) == format))
      |> Map.fetch!(:id)
    end)
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
    control =
      Repo.insert!(%Study.Exam{
        lesson_id: lesson.id,
        questions: questions,
        question_types: Enum.uniq(Enum.map(questions, & &1["type"])),
        instructions: "Instructions SVT"
      })

    definitions =
      CaptainHomework.QuestionDefinitions.available(lesson.subject)
      |> Enum.filter(
        &(CaptainHomework.QuestionDefinitions.engine_format(&1) in control.question_types)
      )

    CaptainHomework.QuestionDefinitions.attach!(control, definitions)
  end
end

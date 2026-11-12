# Opt-in live model check: direnv exec . mix run --no-start scripts/check_ai_comprehension.exs
# Sends only the fictional fixtures below. Does not start Repo, read user data,
# persist exams, synthesize audio, or run application workers. Uses API credits.
Application.ensure_all_started(:req)

alias CaptainHomework.AI.OpenAI
alias CaptainHomework.Exams.{Flashcards, Instructions, TypeContract}

source = %{
  id: "fictional-source",
  kind: "resource",
  position: 1,
  text:
    "My name is Nina. I was born in Bristol and I live in Manchester. " <>
      "I have a rabbit called Snow. I play volleyball every Tuesday. " <>
      "I enjoy jazz music from the fifties and sixties."
}

type = %{
  "id" => "fictional-mcq",
  "name" => "QCM",
  "revision" => 1,
  "instruction_kind" => "dynamic",
  "instruction" => nil,
  "content_kind" => "text",
  "content_presence" => "optional",
  "response_kind" => "single_choice",
  "work_duration" => "quick",
  "modes" => ["classic", "flashcard"],
  "subjects" => ["anglais"],
  "example" => %{}
}

missing = %{
  "id" => "fictional-question",
  "plan_id" => "fictional-question",
  "type" => "mcq",
  "type_contract" => type,
  "prompt" => "Where was Nina born?",
  "text" => "",
  "answer" => "Bristol",
  "options" => ["Bristol", "Manchester", "Liverpool"],
  "slots" => [],
  "points" => 1,
  "rubric" => "1 point for Bristol.",
  "response_effort" => "direct",
  "answer_basis" => "knowledge",
  "source_page_ids" => [source.id],
  "support_id" => "",
  "image_ids" => []
}

context = %{source_pages: [source], subject: "anglais", lesson_title: "Introducing yourself"}
{:ok, accepted, errors} = OpenAI.audit_response_effort([missing], context)
IO.inspect(%{accepted: length(accepted), errors: errors}, label: "Missing document audit")
if accepted != [], do: raise("Audit accepted a hidden narrative")

type_context = TypeContract.context([type], "flashcard", "anglais")
instructions = Instructions.compose("", "", type_context)
lesson = %CaptainHomework.Study.Lesson{title: "Introducing yourself", subject: "anglais"}
{:ok, generated} = OpenAI.generate_flashcards(lesson, [source], 3, instructions, [], ["mcq"])

IO.inspect(Enum.map(generated, &Map.take(&1, ~w(prompt text answer_basis))), label: "Fresh cards")
{valid, []} = Flashcards.validate_candidates(generated, [source])
if length(valid) != 3, do: raise("Flashcard validation failed")
{:ok, accepted, errors} = OpenAI.audit_response_effort(generated, context)
IO.inspect(%{accepted: length(accepted), errors: errors}, label: "Fresh cards audit")
if length(accepted) != 3, do: raise("Generated cards failed semantic audit")

listening = %{
  "type" => "listening",
  "prompt" => "What kind of music does Nina enjoy?",
  "answer" => "50s and 60s jazz music",
  "rubric" =>
    "1 point for 50s and 60s jazz music. 0.75 for a very close answer. " <>
      "0.5 for jazz music. 0 otherwise.",
  "audio_script" => %{"text" => source.text},
  "points" => 1
}

for format <- ["flashcard", "classic"] do
  cases = [
    {"fifties and sixties jazz music", 1},
    {"50s and 60s jazz music", 1},
    {"eighties and nineties jazz music", :partial},
    {"jazz music", 0.5}
  ]

  qs =
    Enum.with_index(cases, fn {answer, expected}, i ->
      {Map.put(listening, "id", "test-#{i}"), answer, expected}
    end)

  exam = %{
    format: format,
    questions: Enum.map(qs, &elem(&1, 0)),
    answers: Map.new(qs, fn {q, answer, _} -> {q["id"], answer} end)
  }

  {:ok, result} = OpenAI.grade(exam)

  Enum.each(qs, fn {q, answer, expected} ->
    grade = Enum.find(result["grades"], &(&1["id"] == q["id"]))

    IO.inspect(
      %{format: format, answer: answer, fraction: grade["fraction"], feedback: grade["feedback"]},
      label: "Grading check"
    )

    if expected == :partial do
      if grade["fraction"] >= 1, do: raise("Wrong decades received full credit")
    else
      if grade["fraction"] != expected,
        do: raise("Equivalent or partial answer incorrectly graded")

      if expected == 1 and grade["language_errors"] != [], do: raise("Spurious language error")
    end
  end)
end

IO.puts("All live checks passed. Only fictional data sent; no exam persisted.")

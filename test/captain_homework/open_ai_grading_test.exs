defmodule CaptainHomework.OpenAIGradingTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.AI.OpenAI
  alias CaptainHomework.Exams.Flashcards

  setup do
    keys = [
      :openai_api_key,
      :openai_request_options,
      :openai_model,
      :openai_flashcard_model,
      :ai_provider
    ]

    previous = Map.new(keys, &{&1, Application.fetch_env(:captain_homework, &1)})
    Application.put_env(:captain_homework, :openai_api_key, "test-only-key")
    Application.put_env(:captain_homework, :openai_request_options, plug: {Req.Test, __MODULE__})
    Application.put_env(:captain_homework, :openai_model, "configured-main-model")
    Application.delete_env(:captain_homework, :openai_flashcard_model)
    Application.put_env(:captain_homework, :ai_provider, OpenAI)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:captain_homework, key, value)
        {key, :error} -> Application.delete_env(:captain_homework, key)
      end)
    end)

    :ok
  end

  test "flashcard grading uses the fast model for the current card and saves its correction" do
    p = profile()
    questions = Enum.map(["q1", "q2"], &(question(&1, "definition") |> Map.put("points", 1)))

    e =
      exam(lesson(p), questions)
      |> Ecto.Changeset.change(format: "flashcard")
      |> Repo.update!()

    annotation = %{
      "field" => "",
      "original" => "chat",
      "replacement" => "chats",
      "occurrence" => 1,
      "explanation" => "Le déterminant les impose le pluriel."
    }

    grade = %{
      "id" => "q1",
      "fraction" => 0.75,
      "feedback" => "Presque complet.",
      "language_errors" => [annotation]
    }

    stub_response(%{"grades" => [grade], "appreciation" => "Continue tes révisions."})

    assert {:ok, graded} = Flashcards.submit(p.id, e.id, "q1", "Les chat", sync: true)
    assert_receive {:openai_request, request}
    assert request["model"] == "gpt-5.4-mini"
    assert request["reasoning"] == %{"effort" => "none"}

    [_, copy] = String.split(prompt(request), "Copie : ", parts: 2)
    assert [%{"id" => "q1", "student_answer" => "Les chat"}] = Jason.decode!(String.trim(copy))
    assert graded.status == "in_progress"
    assert graded.card_index == 0
    assert graded.error == nil
    assert Map.keys(graded.corrections) == ["q1"]
    assert graded.corrections["q1"]["fraction"] == 0.75
    assert graded.corrections["q1"]["points"] == 0.75
    assert graded.corrections["q1"]["feedback"] == "Presque complet."

    assert [
             %{
               "original" => "chat",
               "replacement" => "chats",
               "explanation" => "Le déterminant les impose le pluriel.",
               "start" => 4,
               "length" => 4
             }
           ] = graded.corrections["q1"]["language_errors"]
  end

  test "flashcard grading respects its dedicated model override" do
    Application.put_env(:captain_homework, :openai_flashcard_model, "configured-flashcard-model")
    e = %{exam(lesson(profile())) | format: "flashcard"}
    result = grading_result()
    stub_response(result)

    assert {:ok, ^result} = OpenAI.grade(e)
    assert_receive {:openai_request, request}
    assert request["model"] == "configured-flashcard-model"
    assert request["reasoning"] == %{"effort" => "none"}
  end

  test "a classic exam with one question keeps the general model and reasoning" do
    Application.put_env(:captain_homework, :openai_flashcard_model, "configured-flashcard-model")
    e = exam(lesson(profile()))
    result = grading_result()
    stub_response(result)

    assert {:ok, ^result} = OpenAI.grade(e)
    assert_receive {:openai_request, request}
    assert request["model"] == "configured-main-model"
    assert request["reasoning"] == %{"effort" => "low"}
  end

  test "flashcard generation keeps the general model and reasoning" do
    Application.put_env(:captain_homework, :openai_flashcard_model, "configured-flashcard-model")
    l = lesson(profile())
    source = page(l)
    card = question("q1", "definition") |> Map.put("source_page_ids", [source.id])
    stub_response(%{"questions" => [card]})

    assert {:ok, [%{"id" => "q1"}]} =
             OpenAI.generate_flashcards(l, [source], 1, "", [], ["definition"])

    assert_receive {:openai_request, request}
    assert request["model"] == "configured-main-model"
    assert request["reasoning"] == %{"effort" => "low"}
  end

  test "shared copies are graded for an anonymous pupil" do
    p = profile()
    original = exam(lesson(p))
    {:ok, _, token} = CaptainHomework.ExamShares.create(p.id, original.id, "fill")
    {:ok, _, attempt} = CaptainHomework.ExamShares.open(token, "visitor")
    stub_response(grading_result())

    assert {:ok, _} = OpenAI.grade(attempt)
    assert_receive {:openai_request, request}
    assert prompt(request) =~ "élève anonyme"
    assert prompt(request) =~ "sans prénom"
    refute prompt(request) =~ p.name
  end

  defp grading_result do
    %{
      "appreciation" => "Continue tes révisions.",
      "grades" => [
        %{"id" => "q1", "fraction" => 1, "feedback" => "Correct.", "language_errors" => []}
      ]
    }
  end

  defp stub_response(result) do
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:openai_request, Jason.decode!(body)})

      Req.Test.json(conn, %{
        "status" => "completed",
        "output" => [
          %{"content" => [%{"type" => "output_text", "text" => Jason.encode!(result)}]}
        ]
      })
    end)
  end

  defp prompt(request),
    do: get_in(request, ["input", Access.at(0), "content", Access.at(0), "text"])
end

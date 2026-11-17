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

  for format <- ["classic", "flashcard"] do
    @format format
    test "#{format} grading includes conservative language review and rejects a copied context" do
      answer = "être coupé des flux mondiaux"

      e = %{
        exam(lesson(profile()), [question("q1", "definition")])
        | format: @format,
          answers: %{"q1" => answer}
      }

      annotation = %{
        "field" => "",
        "original" => "être",
        "replacement" => "être coupé",
        "occurrence" => 1,
        "explanation" => "Il faut dire « être coupé »."
      }

      result =
        update_in(
          grading_result(),
          ["grades", Access.at(0)],
          &Map.put(&1, "language_errors", [annotation])
        )

      stub_response(result)

      assert {:ok, response} = OpenAI.grade(e)
      assert_receive {:openai_request, request}
      text = prompt(request)
      assert text =~ "en cas de doute, ne propose aucune correction"
      assert text =~ "applique toutes les modifications proposées à la réponse"
      assert text =~ "partent. Où"
      assert text =~ "L'explication doit décrire exactement la modification"

      assert {:ok, %{"q1" => %{"language_errors" => [], "fraction" => 1}}, 20.0} =
               CaptainHomework.Exams.validate_grades(e, response)
    end

    test "#{format} grading treats written-out decades as equivalent without changing the answer" do
      q =
        question("q1", "listening")
        |> Map.merge(%{
          "prompt" => "What kind of music is Tom a big fan of?",
          "answer" => "60s and 70s rock music",
          "rubric" => "1 point pour 60s and 70s rock music.",
          "audio_script" => %{"text" => "I'm a big fan of 60s and 70s rock music."}
        })

      answer = "sixties and seventies rock music"
      e = %{exam(lesson(profile(), "anglais"), [q]) | format: @format, answers: %{"q1" => answer}}
      stub_response(grading_result())
      assert {:ok, result} = OpenAI.grade(e)
      assert_receive {:openai_request, request}
      text = prompt(request)

      assert text =~
               "Les nombres, dates et décennies écrits en lettres ou en chiffres sont équivalents"

      assert text =~ "consigne VISIBLE"
      [_, copy] = String.split(text, "Copie : ", parts: 2)
      assert [%{"student_answer" => ^answer}] = Jason.decode!(String.trim(copy))

      assert {:ok, %{"q1" => %{"fraction" => 1}}, 20.0} =
               CaptainHomework.Exams.validate_grades(e, result)
    end
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

  test "contestation revises a mistaken answer and preserves other corrections" do
    p = profile()
    questions = [question("q1", "definition"), question("q2", "definition")]
    e = exam(lesson(p), questions)
    answers = %{"q1" => "4/11", "q2" => "Une réponse"}

    {:ok, corrections, score} =
      CaptainHomework.Exams.validate_grades(%{e | answers: answers}, [
        %{"id" => "q1", "fraction" => 0, "feedback" => "Incorrect"},
        %{"id" => "q2", "fraction" => 1, "feedback" => "Correct"}
      ])

    e =
      e
      |> Ecto.Changeset.change(
        status: "completed",
        answers: answers,
        corrections: corrections,
        score: score
      )
      |> Repo.update!()

    result = %{
      "appreciation" => "Très bon travail.",
      "grades" => [
        %{
          "id" => "q1",
          "fraction" => 1,
          "expected" => "4/11",
          "feedback" => "4 carreaux sur 11.",
          "language_errors" => []
        }
      ]
    }

    stub_response(result)

    assert {:ok, updated} =
             CaptainHomework.Exams.Contestation.submit(p.id, e.id, "q1", "Il y a 11 carreaux.")

    assert updated.score == 20.0
    assert updated.answers == answers
    assert updated.corrections["q2"] == corrections["q2"]
    assert Enum.at(updated.questions, 1) == Enum.at(e.questions, 1)
    assert hd(updated.questions)["answer"] == "4/11"
    assert updated.corrections["q1"]["expected"] == "4/11"

    assert [%{"explanation" => "Il y a 11 carreaux."}] =
             updated.corrections["q1"]["contestations"]

    assert_receive {:openai_request, request}
    assert prompt(request) =~ "Le corrigé initial"
    assert prompt(request) =~ "Il y a 11 carreaux."

    assert get_in(request, [
             "text",
             "format",
             "schema",
             "properties",
             "grades",
             "items",
             "properties",
             "expected"
           ]) == %{"type" => "string"}
  end

  test "invalid reconsideration leaves the persisted exam unchanged" do
    p = profile()
    e = exam(lesson(p))

    e =
      e
      |> Ecto.Changeset.change(
        status: "completed",
        answers: %{"q1" => "Réponse"},
        corrections: %{
          "q1" => %{"points" => 0, "fraction" => 0, "expected" => "Ancien", "feedback" => "Non"}
        },
        score: 0.0
      )
      |> Repo.update!()

    stub_response(%{"grades" => [], "appreciation" => "Incomplet"})
    assert {:error, _} = CaptainHomework.Exams.Contestation.submit(p.id, e.id, "q1", "")
    assert Repo.reload!(e) == e
    assert {:error, _} = CaptainHomework.Exams.Contestation.submit(p.id, e.id, "unknown", "")
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

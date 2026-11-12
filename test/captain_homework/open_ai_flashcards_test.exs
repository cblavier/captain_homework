defmodule CaptainHomework.OpenAIFlashcardsTest do
  use CaptainHomework.DataCase, async: false
  import CaptainHomework.Fixtures
  alias CaptainHomework.{AI, Exams, Repo, Study}

  setup do
    keys = [:openai_api_key, :openai_request_options, :ai_provider]
    previous = Map.new(keys, &{&1, Application.fetch_env(:captain_homework, &1)})
    Application.put_env(:captain_homework, :openai_api_key, "test-only-key")
    Application.put_env(:captain_homework, :openai_request_options, plug: {Req.Test, __MODULE__})
    Application.put_env(:captain_homework, :ai_provider, AI.OpenAI)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:captain_homework, key, value)
        {key, :error} -> Application.delete_env(:captain_homework, key)
      end)
    end)

    :ok
  end

  test "resource-only flashcards explicitly use transcripts as learning material" do
    l = lesson(profile(), "anglais")

    source = %{
      id: Ecto.UUID.generate(),
      kind: "resource",
      text: "The weather is lovely today.",
      position: 1
    }

    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      prompt = get_in(request, ["input", Access.at(0), "content", Access.at(0), "text"])
      send(owner, {:transcript_prompt, prompt})
      Plug.Conn.send_resp(conn, 503, "unavailable")
    end)

    assert {:error, _} = AI.OpenAI.generate_flashcards(l, [source], 1, "", [], ["definition"])
    assert_receive {:transcript_prompt, prompt}
    assert prompt =~ "Ce chapitre ne contient pas de page de leçon"
    assert prompt =~ "transcriptions audio"
    assert prompt =~ source.text
    assert prompt =~ source.id
    refute prompt =~ "N’utilise aucun contrôle de référence, ressource externe"
  end

  test "narrative comprehension is repaired with a visible excerpt instead of hidden recall" do
    l = lesson(profile(), "anglais")
    excerpt = "Hi, I'm Tom. I come from Yorkshire, and I was born in Leeds."
    source = page(l) |> Ecto.Changeset.change(text: excerpt) |> Repo.update!()
    calls = start_supervised!({Agent, fn -> 0 end})

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      [%{"content" => [%{"text" => prompt}]}] = request["input"]
      properties = request["text"]["format"]["schema"]["properties"]

      result =
        if properties["questions"] do
          assert properties["questions"]["items"]["properties"]["answer_basis"]["enum"] ==
                   ["knowledge", "document"]

          assert prompt =~ "Les détails personnels du narrateur ne sont pas des connaissances"
          attempt = Agent.get_and_update(calls, &{&1, &1 + 1})

          q =
            question("tom", "mcq")
            |> Map.merge(%{
              "prompt" => "Where was Tom born?",
              "text" => if(attempt == 0, do: "", else: excerpt),
              "answer_basis" => if(attempt == 0, do: "knowledge", else: "document"),
              "options" => ["London", "Leeds", "Yorkshire"],
              "answer" => "Leeds",
              "rubric" => "1 point for Leeds.",
              "source_page_ids" => [source.id]
            })

          %{"questions" => [q]}
        else
          assert prompt =~ "Même sans renvoi"
          assert prompt =~ "Where was Tom born?"
          [q] = prompt |> String.trim() |> String.split("\n") |> List.last() |> Jason.decode!()
          visible? = q["text"] == excerpt

          %{
            "reviews" => [
              %{
                "plan_id" => q["plan_id"],
                "actual_effort" => "direct",
                "actual_basis" => "document",
                "answer_exposed" => false,
                "content_consistent" => visible?,
                "consistent" => visible?,
                "reason" =>
                  if(visible?,
                    do: "Compréhension autonome.",
                    else: "Le témoignage est caché : fournir un extrait visible."
                  )
              }
            ]
          }
        end

      Req.Test.json(conn, %{
        "status" => "completed",
        "output" => [
          %{"content" => [%{"type" => "output_text", "text" => Jason.encode!(result)}]}
        ]
      })
    end)

    assert {:ok, generated} =
             Exams.generate(l.profile_id, l.id, 1, "",
               format: "flashcard",
               question_types: question_type_ids(["mcq"])
             )

    assert generated.status == "in_progress", inspect(generated.generation_errors)
    assert [q] = generated.questions
    assert q["text"] == excerpt
    assert q["answer_basis"] == "document"
    assert q["verified_answer_basis"] == "document"
    assert Agent.get(calls, & &1) == 2
  end

  test "a fixed flashcard instruction is assembled locally before audit" do
    l = lesson(profile())
    source = page(l)
    [id] = question_type_ids(["definition"])
    type = CaptainHomework.QuestionDefinitions.get!(id)

    {:ok, type} =
      CaptainHomework.QuestionDefinitions.save(type, %{
        instruction_kind: "fixed",
        instruction: "Définis le terme suivant.",
        content_presence: "required"
      })

    calls = start_supervised!({Agent, fn -> [] end})

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      properties = request["text"]["format"]["schema"]["properties"]

      result =
        if properties["questions"] do
          fields = properties["questions"]["items"]["properties"]
          assert fields["definition_id"]["enum"] == [id]
          refute Map.has_key?(fields, "prompt")
          assert fields["text"]["pattern"] == "\\S"
          Agent.update(calls, &(&1 ++ [:generation]))

          %{
            "questions" => [
              question("q1", "definition")
              |> Map.merge(%{
                "definition_id" => id,
                "prompt" => type.instruction,
                "text" => "Membrane",
                "points" => 1,
                "source_page_ids" => [source.id]
              })
              |> Map.drop(["prompt", "options", "slots", "diagram"])
            ]
          }
        else
          Agent.update(calls, &(&1 ++ [:audit]))
          [%{"content" => [%{"text" => prompt}]}] = request["input"]

          questions =
            prompt |> String.trim() |> String.split("\n") |> List.last() |> Jason.decode!()

          assert Enum.all?(questions, &(&1["prompt"] == type.instruction))

          %{
            "reviews" =>
              Enum.map(questions, fn q ->
                %{
                  "plan_id" => q["plan_id"],
                  "actual_effort" => "direct",
                  "actual_basis" => "knowledge",
                  "answer_exposed" => false,
                  "consistent" => true,
                  "reason" => "Définition cohérente."
                }
              end)
          }
        end

      Req.Test.json(conn, %{
        "status" => "completed",
        "output" => [
          %{"content" => [%{"type" => "output_text", "text" => Jason.encode!(result)}]}
        ]
      })
    end)

    assert {:ok, generated} =
             Exams.generate(l.profile_id, l.id, 1, "", format: "flashcard", question_types: [id])

    assert generated.status == "in_progress", inspect(generated.generation_errors)
    assert [q] = generated.questions
    assert q["prompt"] == type.instruction
    assert q["type_contract"]["revision"] == type.revision
    assert Agent.get(calls, & &1) == [:generation, :audit]
  end

  test "chronological flashcards use numbered events and a permutation as their expected answer" do
    {:ok, _} = CaptainHomework.QuestionDefinitions.seed!()

    type =
      Enum.find(CaptainHomework.QuestionDefinitions.list(), &(&1.response_kind == "ordering"))

    l = lesson(profile(), "histoire-geo")
    source = page(l)

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      schema = request["text"]["format"]["schema"]["properties"]
      [%{"content" => [%{"text" => prompt}]}] = request["input"]

      result =
        if schema["questions"] do
          assert schema["questions"]["items"]["properties"]["type"]["enum"] == ["ordering"]
          assert prompt =~ "l’interface les numérote de 1 à N"

          %{
            "questions" => [
              question("q1", "ordering")
              |> Map.merge(%{
                "prompt" => "Classe ces événements du plus ancien au plus récent.",
                "options" => ["Écriture", "Maîtrise du feu", "Agriculture"],
                "answer" => "2, 3, 1",
                "points" => 1,
                "source_page_ids" => [source.id]
              })
            ]
          }
        else
          questions =
            prompt |> String.trim() |> String.split("\n") |> List.last() |> Jason.decode!()

          %{
            "reviews" =>
              Enum.map(questions, fn q ->
                %{
                  "plan_id" => q["plan_id"],
                  "actual_effort" => "direct",
                  "actual_basis" => "knowledge",
                  "answer_exposed" => false,
                  "exposure_source_id" => "",
                  "exposure_quote" => "",
                  "consistent" => true,
                  "reason" => "Classement de faits appris."
                }
              end)
          }
        end

      Req.Test.json(conn, %{
        "status" => "completed",
        "output" => [
          %{"content" => [%{"type" => "output_text", "text" => Jason.encode!(result)}]}
        ]
      })
    end)

    assert {:ok, generated} =
             Exams.generate(l.profile_id, l.id, 1, "",
               format: "flashcard",
               question_types: [type.id]
             )

    assert generated.status == "in_progress"
    assert [%{"type" => "ordering", "answer" => "2, 3, 1"}] = generated.questions
  end

  test "real generation adapter sends only course pages, enforces one point and audits quick recall" do
    p = profile()
    l = lesson(p)
    first = page(l)

    second =
      page(l)
      |> Ecto.Changeset.change(text: "Le noyau contient l'information génétique.")
      |> Repo.update!()

    page(l)
    |> Ecto.Changeset.change(kind: "example", text: "EXAMPLE_SHOULD_NOT_BE_SENT")
    |> Repo.update!()

    resource =
      Repo.insert!(%Study.Resource{lesson_id: l.id, filename: "Resource", status: "ready"})

    page(l)
    |> Ecto.Changeset.change(
      kind: "resource",
      resource_id: resource.id,
      text: "RESOURCE_SHOULD_NOT_BE_SENT"
    )
    |> Repo.update!()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      [%{"content" => [%{"type" => "input_text", "text" => prompt}]}] = request["input"]
      refute String.contains?(prompt, "EXAMPLE_SHOULD_NOT_BE_SENT")
      refute String.contains?(prompt, "RESOURCE_SHOULD_NOT_BE_SENT")
      schema = request["text"]["format"]["schema"]["properties"]

      result =
        if schema["questions"] do
          assert String.contains?(prompt, first.text)
          assert String.contains?(prompt, second.text)
          properties = schema["questions"]["items"]["properties"]
          assert properties["points"]["enum"] == [1]
          assert properties["type"]["enum"] == ["definition"]

          %{
            "questions" => [
              question("q", "definition")
              |> Map.merge(%{"points" => 1, "source_page_ids" => [first.id]})
            ]
          }
        else
          assert schema["reviews"]

          questions =
            prompt |> String.trim() |> String.split("\n") |> List.last() |> Jason.decode!()

          %{
            "reviews" =>
              Enum.map(questions, fn q ->
                %{
                  "plan_id" => q["plan_id"],
                  "actual_effort" => "direct",
                  "actual_basis" => "knowledge",
                  "answer_exposed" => false,
                  "exposure_source_id" => "",
                  "exposure_quote" => "",
                  "consistent" => true,
                  "reason" => "Rappel rapide du cours."
                }
              end)
          }
        end

      Req.Test.json(conn, %{
        "status" => "completed",
        "output" => [
          %{"content" => [%{"type" => "output_text", "text" => Jason.encode!(result)}]}
        ]
      })
    end)

    assert {:ok, generated} =
             Exams.generate(p.id, l.id, 1, "",
               format: "flashcard",
               question_types: question_type_ids(["definition", "long"])
             )

    assert generated.status == "in_progress"

    assert [
             %{
               "points" => 1,
               "verified_response_effort" => "direct",
               "verified_answer_basis" => "knowledge"
             }
           ] = generated.questions

    assert generated.generation_plan == nil
  end

  test "hidden numbered vocabulary is rejected and repaired while autonomous cards are kept" do
    p = profile()
    l = lesson(p)

    source =
      page(l)
      |> Ecto.Changeset.change(text: "Halloween vocabulary\n1. bat\n2. candle\n3. ghost")
      |> Repo.update!()

    translation =
      question("translation", "definition")
      |> Map.merge(%{
        "prompt" => "Traduis « bougie » en anglais.",
        "answer" => "candle",
        "rubric" => "1 point pour candle.",
        "source_page_ids" => [source.id]
      })

    missing_list =
      question("missing-list", "mcq")
      |> Map.merge(%{
        "prompt" => "QCM : Quel mot correspond au numéro 1 dans la liste ?",
        "options" => ["bat", "ghost", "cat"],
        "answer" => "bat",
        "rubric" => "1 point pour bat.",
        "source_page_ids" => [source.id]
      })

    repaired = Map.put(missing_list, "prompt", "Quel mot anglais signifie chauve-souris ?")
    drafts = start_supervised!({Agent, fn -> 0 end})
    owner = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)
      [%{"content" => [%{"type" => "input_text", "text" => prompt}]}] = request["input"]
      schema = request["text"]["format"]["schema"]["properties"]

      result =
        if schema["questions"] do
          assert prompt =~ "Les documents sources et leur texte reconnu ne sont pas affichés"

          case Agent.get_and_update(drafts, &{&1, &1 + 1}) do
            0 ->
              %{"questions" => [translation, missing_list]}

            1 ->
              assert prompt =~ "Crée exactement 1 flashcards"
              assert prompt =~ "Diagnostics"
              saved = Repo.one!(Study.Exam)
              assert [kept] = saved.questions
              assert kept["prompt"] == translation["prompt"]
              send(owner, {:kept_card, kept["id"]})
              %{"questions" => [repaired]}
          end
        else
          assert prompt =~ "Une source OCR qui contient ces éléments ne les rend pas"

          questions =
            prompt |> String.trim() |> String.split("\n") |> List.last() |> Jason.decode!()

          # Even an auditor approving everything never sees the unusable draft.
          refute Enum.any?(questions, &(&1["prompt"] == missing_list["prompt"]))

          %{
            "reviews" =>
              Enum.map(questions, fn q ->
                %{
                  "plan_id" => q["plan_id"],
                  "actual_effort" => "direct",
                  "actual_basis" => "knowledge",
                  "answer_exposed" => false,
                  "exposure_source_id" => "",
                  "exposure_quote" => "",
                  "consistent" => true,
                  "reason" => "Rappel rapide du cours."
                }
              end)
          }
        end

      Req.Test.json(conn, %{
        "status" => "completed",
        "output" => [
          %{"content" => [%{"type" => "output_text", "text" => Jason.encode!(result)}]}
        ]
      })
    end)

    assert {:ok, generated} =
             Exams.generate(p.id, l.id, 2, "",
               format: "flashcard",
               question_types: question_type_ids(["definition", "mcq"])
             )

    assert generated.status == "in_progress"
    assert generated.generation_errors == []

    assert Enum.map(generated.questions, & &1["prompt"]) ==
             [translation["prompt"], repaired["prompt"]]

    assert_receive {:kept_card, kept_id}
    assert hd(generated.questions)["id"] == kept_id
    assert Agent.get(drafts, & &1) == 2
  end
end

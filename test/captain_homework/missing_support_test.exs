defmodule CaptainHomework.MissingSupportTest do
  use ExUnit.Case, async: true
  alias CaptainHomework.AI

  defp question(prompt) do
    %{
      "type" => "mcq",
      "prompt" => prompt,
      "text" => "",
      "options" => ["bat", "candle", "witch"],
      "answer" => "bat",
      "rubric" => "Un point pour la bonne réponse.",
      "points" => 1,
      "slots" => [],
      "diagram" => nil,
      "image_ids" => []
    }
  end

  test "rejects the thirteen production questions referring to an invisible numbered list" do
    for number <- 1..13 do
      q = question("QCM : Quel mot correspond au numéro #{number} dans la liste ?")

      assert [error] = AI.question_errors(q)
      assert error =~ "liste numérotée absente"
    end
  end

  test "also rejects abbreviated references and whitespace-only support" do
    for reference <- ["n° 2", "Nº2", "NUMÉRO 2"] do
      q =
        question("Quel mot correspond au #{reference} dans cette liste ?")
        |> Map.put("text", " \n\t ")

      assert [_error] = AI.question_errors(q)
    end
  end

  test "permits autonomous vocabulary questions and ordinary numerical facts" do
    for prompt <- [
          "Quel mot anglais signifie « chauve-souris » ?",
          "Dans la liste de choix, quel mot anglais signifie « chauve-souris » ?",
          "Quel mot anglais désigne un animal qui possède 2 ailes ?",
          "Quel est le numéro atomique de l’hydrogène ?"
        ] do
      assert AI.question_errors(question(prompt)) == []
    end
  end

  test "permits the referenced entry when the list appears in the visible prompt" do
    for list <- ["1. bat\n2. candle", "1) bat ; 2) candle", "1 : bat, 2 : candle"] do
      q = question("Liste : #{list}\nQuel mot correspond au numéro 2 dans la liste ?")
      assert AI.question_errors(q) == []
    end
  end

  test "an unrelated list entry and the mention of a number alone do not supply the reference" do
    for prompt <- [
          "Liste : 1. bat\nQuel mot correspond au numéro 2 dans la liste ?",
          "Dans la liste, choisis le mot correspondant au numéro 2. Réponds en anglais."
        ] do
      assert [_error] = AI.question_errors(question(prompt))
    end
  end

  test "permits text and image supports actually attached to the question" do
    q = question("Quel mot correspond au numéro 1 dans la liste ?")

    assert AI.question_errors(Map.put(q, "text", "1. bat\n2. candle")) == []
    assert AI.question_errors(Map.put(q, "image_ids", ["vocabulary-list"])) == []

    assert AI.question_errors(Map.put(q, "images", [%{"storage_key" => "vocabulary-list.png"}])) ==
             []
  end

  test "permits a valid numbered diagram" do
    node = %{"shape" => "rect", "label" => "1", "x" => 0, "y" => 0, "width" => 50, "height" => 50}

    q =
      question("Quel mot correspond au numéro 1 dans la liste illustrée ?")
      |> Map.merge(%{
        "type" => "diagram",
        "options" => [],
        "slots" => ["1"],
        "diagram" => %{"nodes" => [node]}
      })

    assert AI.question_errors(q) == []

    hidden_diagram = Map.merge(q, %{"type" => "mcq", "options" => ["bat", "candle"]})
    assert [_error] = AI.question_errors(hidden_diagram)
  end

  test "permits a shared list once it is attached as the question's visible support" do
    q =
      question("Quel mot correspond au numéro 1 dans la liste ?")
      |> Map.put("plan_id", "q1")

    slots = [%{"id" => "q1", "type" => "mcq", "support_id" => "list"}]
    supports = [%{"id" => "list", "text" => "1. bat\n2. candle", "image_ids" => []}]

    assert {:ok, attached} = CaptainHomework.Exams.Plan.attach(q, slots, supports)
    assert AI.question_errors(attached) == []
  end
end

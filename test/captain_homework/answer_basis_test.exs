defmodule CaptainHomework.AnswerBasisTest do
  use ExUnit.Case, async: true
  alias CaptainHomework.Exams.{AnswerBasis, ResponseEffort}

  @pages [%{id: "course", kind: "lesson"}, %{id: "external", kind: "resource"}]

  test "course origin alone cannot stand in for knowledge questions" do
    knowledge = %{
      "answer_basis" => "knowledge",
      "source_page_ids" => ["course"],
      "support_id" => ""
    }

    document = %{
      "answer_basis" => "document",
      "source_page_ids" => ["course"],
      "support_id" => "s1"
    }

    assert AnswerBasis.valid?([knowledge, document], @pages, ["long"])
    assert AnswerBasis.valid?([document, document], @pages, ["long"])

    refute AnswerBasis.valid?([Map.put(knowledge, "support_id", "s1"), document], @pages, ["long"])

    refute AnswerBasis.valid?(
             [Map.put(knowledge, "source_page_ids", ["external"]), document],
             @pages,
             ["long"]
           )
  end

  test "review rejects knowledge answered by any visible document, even if effort matches" do
    q = %{"plan_id" => "q1", "response_effort" => "direct", "answer_basis" => "knowledge"}

    review = %{
      "plan_id" => "q1",
      "actual_effort" => "direct",
      "consistent" => true,
      "actual_basis" => "document",
      "answer_exposed" => true,
      "reason" => "La réponse est dans un autre support"
    }

    assert {:ok, [], [_]} = ResponseEffort.review([q], [review])
    safe = Map.merge(review, %{"actual_basis" => "knowledge", "answer_exposed" => false})
    assert {:ok, [accepted], []} = ResponseEffort.review([q], [safe])
    assert accepted["verified_answer_basis"] == "knowledge"
    assert {:ok, [], [_]} = ResponseEffort.review([q], [Map.put(safe, "answer_exposed", true)])
  end

  test "finding an answer in its document is allowed for a document question" do
    q = %{"plan_id" => "q1", "response_effort" => "direct", "answer_basis" => "document"}

    review = %{
      "plan_id" => "q1",
      "actual_effort" => "direct",
      "consistent" => true,
      "actual_basis" => "document",
      "answer_exposed" => true,
      "reason" => "Lecture de carte"
    }

    assert {:ok, [_], []} = ResponseEffort.review([q], [review])
  end

  test "visual interpretation may use learned vocabulary but still rejects inconsistent content" do
    q = %{
      "plan_id" => "q1",
      "response_effort" => "direct",
      "answer_basis" => "document",
      "image_ids" => ["image"]
    }

    review = %{
      "plan_id" => "q1",
      "actual_effort" => "direct",
      "consistent" => true,
      "actual_basis" => "knowledge",
      "answer_exposed" => false,
      "reason" => ""
    }

    assert {:ok, [_], []} = ResponseEffort.review([q], [review])
    assert {:ok, [], [_]} = ResponseEffort.review([q], [Map.put(review, "consistent", false)])
    assert {:ok, [], [_]} = ResponseEffort.review([Map.put(q, "image_ids", [])], [review])
  end

  test "validation reports actual counts and identifies missing course sources and visible supports" do
    questions = [
      %{
        "id" => "q1",
        "answer_basis" => "knowledge",
        "source_page_ids" => ["external"],
        "support_id" => ""
      },
      %{
        "id" => "q2",
        "answer_basis" => "knowledge",
        "source_page_ids" => ["course"],
        "support_id" => "s1"
      }
    ]

    errors = AnswerBasis.validation_errors(questions, @pages, ["long"])
    assert Enum.any?(errors, &(&1 =~ "sans source de leçon : q1"))
    assert Enum.any?(errors, &(&1 =~ "support visible à retirer : q2"))
  end
end

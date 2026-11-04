defmodule CaptainHomework.ResponseEffortTest do
  use ExUnit.Case, async: true
  alias CaptainHomework.Exams.ResponseEffort

  test "review reclassifies consistent work and rejects extra grading requirements" do
    questions = for id <- ~w(q2 q4 q6 q10), do: %{"plan_id" => id, "response_effort" => "short"}

    reviews = [
      %{
        "plan_id" => "q2",
        "actual_effort" => "developed",
        "consistent" => true,
        "reason" => "Deux demandes"
      },
      %{
        "plan_id" => "q4",
        "actual_effort" => "direct",
        "consistent" => true,
        "reason" => "Liste à citer"
      },
      %{
        "plan_id" => "q6",
        "actual_effort" => "short",
        "consistent" => false,
        "reason" => "Argument supplémentaire au barème"
      },
      %{
        "plan_id" => "q10",
        "actual_effort" => "short",
        "consistent" => true,
        "reason" => "Une idée"
      }
    ]

    assert {:ok, accepted, errors} = ResponseEffort.review(questions, reviews)
    assert Enum.map(accepted, & &1["plan_id"]) == ~w(q2 q4 q10)
    assert Enum.map(accepted, & &1["response_effort"]) == ~w(developed direct short)
    assert Enum.all?(accepted, &(&1["verified_response_effort"] == &1["response_effort"]))
    assert length(errors) == 1
    assert {:error, :invalid_effort_review} = ResponseEffort.review(questions, tl(reviews))

    assert {:error, :invalid_effort_review} =
             ResponseEffort.review(questions, [hd(reviews) | reviews])
  end

  test "an incompatible response format still requires a real repair" do
    question = %{"plan_id" => "q1", "type" => "mcq", "response_effort" => "direct"}

    review = %{
      "plan_id" => "q1",
      "actual_effort" => "developed",
      "consistent" => true,
      "reason" => "Une rédaction est demandée dans un QCM"
    }

    assert {:ok, [], [_]} = ResponseEffort.review([question], [review])
  end

  test "audit classification does not mutate an immutable contract's effort" do
    question = %{
      "plan_id" => "q1",
      "type" => "long",
      "response_effort" => "short",
      "answer_basis" => "knowledge",
      "exercise_spec_hash" => "frozen-contract"
    }

    review = %{
      "plan_id" => "q1",
      "actual_effort" => "direct",
      "actual_basis" => "knowledge",
      "answer_exposed" => false,
      "consistent" => true,
      "reason" => "La tâche et le barème sont cohérents."
    }

    assert {:ok, [accepted], []} = ResponseEffort.review([question], [review])
    assert Map.take(accepted, Map.keys(question)) == question
    assert accepted["response_effort"] == "short"
    assert accepted["verified_response_effort"] == "direct"
    assert accepted["verified_answer_basis"] == "knowledge"

    assert {:ok, [], [_]} =
             ResponseEffort.review([question], [Map.put(review, "consistent", false)])

    assert {:ok, [], [_]} =
             ResponseEffort.review(
               [Map.merge(question, %{"type" => "mcq", "response_effort" => "direct"})],
               [Map.put(review, "actual_effort", "developed")]
             )
  end
end

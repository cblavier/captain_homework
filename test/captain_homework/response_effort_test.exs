defmodule CaptainHomework.ResponseEffortTest do
  use ExUnit.Case, async: true
  alias CaptainHomework.Exams.ResponseEffort

  test "targets use 40/40/20 and adapt to allowed formats and small counts" do
    assert ResponseEffort.targets(10, ["reading"]) == %{
             "direct" => 4,
             "short" => 4,
             "developed" => 2
           }

    assert ResponseEffort.targets(5, ["long"]) == %{"direct" => 2, "short" => 2, "developed" => 1}
    assert ResponseEffort.targets(3, ["long"]) == %{"direct" => 1, "short" => 1, "developed" => 1}

    assert ResponseEffort.targets(10, ["mcq"]) == %{
             "direct" => 10,
             "short" => 0,
             "developed" => 0
           }

    assert ResponseEffort.targets(10, ["definition"]) == %{
             "direct" => 10,
             "short" => 0,
             "developed" => 0
           }
  end

  test "a mislabeled plan is rejected rather than trusting its categories" do
    questions = for _ <- 1..10, do: %{"response_effort" => "short"}
    refute ResponseEffort.balanced?(questions, ["reading"])
  end

  test "review rejects actual effort mismatches and extra grading requirements" do
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

    assert {:ok, [accepted], errors} = ResponseEffort.review(questions, reviews)
    assert accepted["plan_id"] == "q10"
    assert accepted["verified_response_effort"] == "short"
    assert length(errors) == 3
    assert {:error, :invalid_effort_review} = ResponseEffort.review(questions, tl(reviews))

    assert {:error, :invalid_effort_review} =
             ResponseEffort.review(questions, [hd(reviews) | reviews])
  end
end

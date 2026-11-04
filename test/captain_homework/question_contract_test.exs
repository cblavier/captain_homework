defmodule CaptainHomework.QuestionContractTest do
  use ExUnit.Case, async: true
  alias CaptainHomework.AI.QuestionContract

  test "identities keep retry keys and skip existing generated keys" do
    assert QuestionContract.ids(4, [%{"plan_id" => "retry-stable"}, %{"plan_id" => "q1"}]) ==
             ["retry-stable", "q1", "q2", "q3"]
  end

  test "the schema requires exactly the named entries and excludes frozen content" do
    kept = %{"plan_id" => "retry-stable", "prompt" => "Traduis bat", "answer" => "chauve-souris"}
    frozen = QuestionContract.frozen([kept])

    properties =
      Map.new(~w(id plan_id prompt answer objective support_id), &{&1, %{"type" => "string"}})

    schema = QuestionContract.schema(properties, ["retry-stable", "q1"], frozen)
    assert Enum.sort(schema["required"]) == ["q1", "retry-stable"]
    assert schema["additionalProperties"] == false
    retry = schema["properties"]["retry-stable"]
    assert retry["required"] == ["objective"]
    assert retry["additionalProperties"] == false
    refute Map.has_key?(schema["properties"]["q1"]["properties"], "id")
    refute Map.has_key?(schema["properties"]["q1"]["properties"], "plan_id")
  end

  test "decoding uses application order and frozen contents, never model IDs" do
    kept = %{"plan_id" => "retry-stable", "prompt" => "Traduis bat", "answer" => "chauve-souris"}

    raw = %{
      "questions" => %{
        "q1" => %{"id" => "foreign"},
        "retry-stable" => %{"prompt" => "changed", "support_id" => "changed"}
      },
      "supports" => []
    }

    assert {:ok, result} =
             QuestionContract.decode(raw, ["retry-stable", "q1"], QuestionContract.frozen([kept]))

    assert Enum.map(result["questions"], & &1["id"]) == ["retry-stable", "q1"]
    assert hd(result["questions"])["prompt"] == kept["prompt"]
    assert hd(result["questions"])["support_id"] == ""
  end

  test "retrying a question preserves its task and its separate document" do
    kept = %{
      "plan_id" => "retry-stable",
      "text" => "Qui sont les auteurs ?",
      "support_id" => "s1",
      "support_text" => "Document et source.",
      "image_ids" => ["page"],
      "image_regions" => [
        %{"image_id" => "page", "x" => 0, "y" => 500, "width" => 1000, "height" => 500}
      ]
    }

    raw = %{"questions" => %{"retry-stable" => %{}}, "supports" => []}

    assert {:ok, result} =
             QuestionContract.decode(raw, ["retry-stable"], QuestionContract.frozen([kept]))

    q = hd(result["questions"])
    assert q["text"] == kept["text"]
    assert q["support_text"] == kept["support_text"]
    assert q["image_regions"] == kept["image_regions"]
    assert q["support_id"] == ""
  end

  test "missing, foreign and sequentially renumbered entries are rejected" do
    for questions <- [%{}, %{"other" => %{}}, %{"1" => %{}}, [%{"id" => "q1"}], %{"q1" => nil}] do
      assert {:error, _} =
               QuestionContract.decode(%{"questions" => questions, "supports" => []}, ["q1"])
    end
  end

  test "new documents use originals even if a response contains legacy crop coordinates" do
    crop = %{"image_id" => "map", "x" => 0, "y" => 0, "width" => 500, "height" => 500}

    for regions <- [nil, [], [crop]] do
      question = %{"image_ids" => ["map"], "image_regions" => regions}
      raw = %{"questions" => %{"q1" => question}, "supports" => [Map.put(question, "id", "doc")]}
      assert {:ok, decoded} = QuestionContract.decode(raw, ["q1"])
      assert hd(decoded["questions"])["image_ids"] == ["map"]
      assert hd(decoded["questions"])["image_regions"] == []
      assert hd(decoded["supports"])["image_regions"] == []
    end
  end

  test "a retained historical question without images cannot acquire a new visual" do
    frozen = QuestionContract.frozen([%{"plan_id" => "q1", "prompt" => "Définis un segment."}])

    raw = %{
      "questions" => %{"q1" => %{"image_ids" => ["map"], "image_regions" => []}},
      "supports" => []
    }

    assert {:ok, decoded} = QuestionContract.decode(raw, ["q1"], frozen)
    assert hd(decoded["questions"])["image_ids"] == []
    assert hd(decoded["questions"])["image_regions"] == []
  end
end

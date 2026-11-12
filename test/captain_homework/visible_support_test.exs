defmodule CaptainHomework.Exams.VisibleSupportTest do
  use ExUnit.Case, async: true
  alias CaptainHomework.Exams.{VisibleSupport, AnswerBasis, TypeContract}

  test "an absent document cannot pass a positive model verdict or a wording-only repair" do
    for prompt <- [
          "À partir du document 3 du support illustré, définis cette théorie.",
          "À l’aide du document 3 ci-dessous, définis cette théorie."
        ] do
      q = %{
        "prompt" => prompt,
        "answer_basis" => "document",
        "text" => "",
        "image_ids" => [],
        "support_text" => ""
      }

      assert [_] = VisibleSupport.errors(q)
      refute AnswerBasis.review_ok?(q, %{"actual_basis" => "document"})
      assert [_] = VisibleSupport.errors(Map.put(q, "answer_basis", "knowledge"))

      assert [] =
               VisibleSupport.errors(
                 Map.put(q, "support_text", "Le document original est présent.")
               )
    end
  end

  test "sources and support identifiers alone do not provide a visible document" do
    q = %{
      "answer_basis" => "document",
      "source_page_ids" => ["hidden"],
      "support_id" => "missing"
    }

    assert [_] = VisibleSupport.errors(q)

    assert [] =
             VisibleSupport.errors(%{
               "answer_basis" => "knowledge",
               "prompt" => "Définis la Préhistoire."
             })
  end

  test "a type without content owns the knowledge basis in its generated schema" do
    definition = %{
      "response_kind" => "short_text",
      "content_kind" => "text",
      "content_presence" => "none",
      "instruction_kind" => "dynamic"
    }

    assert TypeContract.constants(definition, :spec, "svt")["answer_basis"] == "knowledge"
  end
end

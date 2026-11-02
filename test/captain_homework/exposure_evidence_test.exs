defmodule CaptainHomework.ExposureEvidenceTest do
  use ExUnit.Case, async: true
  alias CaptainHomework.Exams.ExposureEvidence

  @question %{
    "plan_id" => "q1",
    "type" => "mcq",
    "prompt" => "Quel mode de vie est décrit ?",
    "text" => "",
    "options" => ["Sédentaire", "Nomade"],
    "diagram" => nil
  }
  @review %{
    "plan_id" => "q1",
    "answer_exposed" => true,
    "actual_effort" => "direct",
    "actual_basis" => "knowledge",
    "consistent" => true
  }

  defp review(source, quote),
    do: Map.merge(@review, %{"exposure_source_id" => source, "exposure_quote" => quote})

  test "a hidden OCR page and an unavailable image cannot expose an answer" do
    for source <- ["lesson-page-id", "source:lesson-page-id", "image:lesson-page-id"] do
      [checked] = ExposureEvidence.verify([review(source, "Sédentaire")], [@question], [], [])
      refute checked["answer_exposed"]
    end
  end

  test "the question's own multiple choice options are not proof" do
    [checked] =
      ExposureEvidence.verify([review("question:q1", "Sédentaire")], [@question], [], [])

    refute checked["answer_exposed"]
  end

  test "a quote in another question can still establish a genuine exposure" do
    other =
      Map.merge(@question, %{
        "plan_id" => "q2",
        "prompt" => "Un sédentaire possède un habitat fixe."
      })

    [checked] =
      ExposureEvidence.verify(
        [review("question:q2", "Un sédentaire possède un habitat fixe.")],
        [@question, other],
        [],
        []
      )

    assert checked["answer_exposed"]
  end

  test "text proofs must match the visible support, not a hidden title or invented quote" do
    support = %{
      "id" => "s1",
      "title" => "Titre caché",
      "text" => "Un nomade se déplace.\nIl n'a pas d'habitat fixe."
    }

    for quote <- ["Titre caché", "Un sédentaire possède un habitat fixe."] do
      [checked] =
        ExposureEvidence.verify([review("support:s1", quote)], [@question], [support], [])

      refute checked["answer_exposed"]
    end

    [checked] =
      ExposureEvidence.verify(
        [review("support:s1", "Un nomade se déplace. Il n'a pas d'habitat fixe.")],
        [@question],
        [support],
        []
      )

    assert checked["answer_exposed"]
  end

  test "visual proofs require an image that is actually displayed and a concrete observation" do
    [valid] =
      ExposureEvidence.verify(
        [review("image:visible", "Une flèche désigne le foyer allumé.")],
        [@question],
        [],
        [%{id: "visible"}]
      )

    assert valid["answer_exposed"]

    [empty] =
      ExposureEvidence.verify([review("image:visible", "")], [@question], [], [%{id: "visible"}])

    refute empty["answer_exposed"]
  end

  test "discarding an unsupported exposure does not alter effort or consistency defects" do
    raw =
      review("source:hidden", "Sédentaire")
      |> Map.merge(%{"actual_effort" => "developed", "consistent" => false})

    [checked] = ExposureEvidence.verify([raw], [@question], [], [])
    refute checked["answer_exposed"]
    assert checked["actual_effort"] == "developed"
    refute checked["consistent"]
  end
end

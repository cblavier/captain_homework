defmodule CaptainHomework.QuestionTemplatesTest do
  use ExUnit.Case, async: true
  alias CaptainHomework.QuestionTemplates

  test "substitutes language without interpreting other placeholders or markup" do
    for {subject, language} <- [
          {"anglais", "anglais"},
          {"espagnol", "espagnol"},
          {"francais", "français"},
          {"latin", "latin"}
        ] do
      assert QuestionTemplates.render("Réponds en {langue} : {{1}} {autre}.", subject) ==
               "Réponds en #{language} : {{1}} {autre}."
    end

    assert QuestionTemplates.render(nil, "anglais") == nil
    assert QuestionTemplates.render("{langue}", "svt") == "{langue}"
    assert QuestionTemplates.render("{{langue}}", "anglais") == "{{langue}}"
  end

  test "invalid audio drafts remain available for validation" do
    assert QuestionTemplates.question(%{"audio_script" => %{}}, "anglais") == %{
             "audio_script" => %{"text" => nil}
           }
  end

  test "resolves question content, options, audio and correction without changing identities" do
    question = %{
      "id" => "{langue}",
      "prompt" => "Lis en {langue}",
      "text" => "Mot {langue}",
      "options" => ["En {langue}"],
      "answer" => "En {langue}",
      "help" => "Écris en {langue}",
      "audio_script" => %{"text" => "Un extrait en {langue}", "language" => "en"}
    }

    resolved = QuestionTemplates.question(question, "anglais")
    assert resolved["id"] == "{langue}"
    assert resolved["prompt"] == "Lis en anglais"
    assert resolved["text"] == "Mot anglais"
    assert resolved["options"] == ["En anglais"]
    assert resolved["answer"] == "En anglais"
    assert resolved["help"] == "Écris en anglais"
    assert resolved["audio_script"]["text"] == "Un extrait en anglais"
  end
end

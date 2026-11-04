defmodule CaptainHomework.ExtractionAI do
  def analyze_resource(data, type) do
    callback =
      Application.get_env(:captain_homework, :extraction_analysis_callback, fn _, _ ->
        {:ok, %{"text" => "Exercice : trace un segment [AB].", "document_kind" => "activity"}}
      end)

    callback.(data, type)
  end

  def extract_illustrations(data, type, count, instructions),
    do:
      Application.fetch_env!(:captain_homework, :extraction_test_callback).(
        data,
        type,
        count,
        instructions
      )
end

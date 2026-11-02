defmodule CaptainHomework.InferenceAI do
  def infer_response_format(label, description) do
    send(self(), {:format_inferred, label, description})
    {:ok, "definition"}
  end
end

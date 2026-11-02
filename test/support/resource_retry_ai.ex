defmodule CaptainHomework.ResourceRetryAI do
  def analyze_resource(_, _) do
    Agent.update(CaptainHomework.ResourceRetryCounter, &(&1 + 1))
    {:ok, %{"text" => "Texte reconnu", "document_kind" => "course"}}
  end
end

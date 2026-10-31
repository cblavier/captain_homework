defmodule CaptainHomework.ResourceUIAI do
  def analyze_resource(_, _),
    do: {:ok, %{"text" => "Observe le schéma.", "document_kind" => "activity"}}
end

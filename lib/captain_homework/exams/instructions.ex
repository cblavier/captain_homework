defmodule CaptainHomework.Exams.Instructions do
  @moduledoc "Keeps author instructions separate from generation and repair diagnostics."

  def compose(custom, guidance) do
    Jason.encode!(%{"generation_context" => 1, "custom" => custom, "guidance" => guidance})
  end

  def custom(value) do
    case decode(value) do
      {:ok, custom, _} -> custom
      :plain -> value || ""
    end
  end

  def guidance(value) do
    case decode(value) do
      {:ok, _, guidance} -> guidance
      :plain -> ""
    end
  end

  defp decode(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{"generation_context" => 1, "custom" => custom, "guidance" => guidance}}
      when is_binary(custom) and is_binary(guidance) ->
        {:ok, custom, guidance}

      _ ->
        :plain
    end
  end

  defp decode(_), do: :plain
end

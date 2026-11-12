defmodule CaptainHomework.Exams.Instructions do
  @moduledoc "Keeps author instructions separate from generation and repair diagnostics."

  def compose(custom, guidance, type_context \\ %{}) do
    Jason.encode!(%{
      "generation_context" => 1,
      "custom" => custom,
      "guidance" => guidance,
      "type_context" => type_context
    })
  end

  def type_context(value) do
    with true <- is_binary(value),
         {:ok, %{"type_context" => context}} <- Jason.decode(value),
         true <- is_map(context) do
      %{
        definitions: context["definitions"] || [],
        mode: context["mode"],
        subject: context["subject"]
      }
    else
      _ -> %{definitions: []}
    end
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

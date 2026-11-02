defmodule CaptainHomework.WorkDuration do
  @moduledoc "Durée cible du travail de l’élève, distincte du format et de la longueur de réponse."
  @options [{"quick", "Rapide", 1}, {"medium", "Intermédiaire", 3}, {"long", "Longue", 6}]
  def options, do: @options
  def values, do: Enum.map(@options, &elem(&1, 0))

  def select_options do
    Enum.map(@options, fn {value, label, minutes} ->
      {"#{label} (≈ #{minutes} min)", value}
    end)
  end

  def minutes(value) do
    case Enum.find(@options, &(elem(&1, 0) == value)) do
      {_, _, minutes} -> minutes
      nil -> nil
    end
  end

  def with_default(type) do
    Map.put_new(type, "work_duration", legacy_default(type["format"] || type["id"]))
  end

  defp legacy_default(format) when format in ["mcq", "definition"], do: "quick"
  defp legacy_default(format) when format in ["reading", "long"], do: "long"
  defp legacy_default(_), do: "medium"
end

defmodule CaptainHomework.WorkDuration do
  @moduledoc "Durée cible du travail de l’élève, distincte du format et de la longueur de réponse."
  @options [{"quick", "Rapide", 1}, {"medium", "Intermédiaire", 3}, {"long", "Longue", 6}]
  def options, do: @options
  def values, do: Enum.map(@options, &elem(&1, 0))

  def select_options do
    Enum.map(@options, fn {value, label, _minutes} ->
      {label, value}
    end)
  end

  def minutes(value) do
    case Enum.find(@options, &(elem(&1, 0) == value)) do
      {_, _, minutes} -> minutes
      nil -> nil
    end
  end
end

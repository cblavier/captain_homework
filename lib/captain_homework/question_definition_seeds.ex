defmodule CaptainHomework.QuestionDefinitionSeeds do
  @moduledoc "Données initiales explicites du catalogue commun."
  def all do
    :captain_homework
    |> Application.app_dir("priv/repo/question_definitions.json")
    |> File.read!()
    |> Jason.decode!()
  end
end

defmodule CaptainHomework.Repo.Migrations.AddQuestionTypeWorkDurations do
  use Ecto.Migration

  def up do
    update_types(fn type ->
      duration =
        case type["format"] || type["id"] do
          format when format in ["mcq", "definition"] -> "quick"
          format when format in ["reading", "long"] -> "long"
          _ -> "medium"
        end

      Map.put_new(type, "work_duration", duration)
    end)
  end

  def down, do: update_types(&Map.delete(&1, "work_duration"))

  defp update_types(fun) do
    %{rows: rows} = repo().query!("SELECT id, types FROM subject_question_settings")

    for [id, types] <- rows do
      updated = types |> Jason.decode!() |> Enum.map(fun) |> Jason.encode!()
      repo().query!("UPDATE subject_question_settings SET types = ? WHERE id = ?", [updated, id])
    end
  end
end

defmodule CaptainHomework.Settings do
  alias CaptainHomework.{Repo, Study}
  alias CaptainHomework.Settings.Prompt

  def get, do: Repo.get(Prompt, 1) || %Prompt{id: 1, instructions: Study.builtin_instructions()}
  def instructions, do: get().instructions
  def change, do: Prompt.changeset(get(), %{})

  def save(attrs) do
    %Prompt{id: 1}
    |> Prompt.changeset(attrs)
    |> Repo.insert(on_conflict: {:replace, [:instructions, :updated_at]}, conflict_target: :id)
  end
end

defmodule CaptainHomework.Repo.Migrations.AddDisabledSubjectsToProfiles do
  use Ecto.Migration

  def change do
    alter table(:profiles) do
      add :disabled_subjects, {:array, :string}, default: [], null: false
    end
  end
end

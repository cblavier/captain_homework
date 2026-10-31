defmodule CaptainHomework.Repo.Migrations.AddEnvironmentKeyToProfiles do
  use Ecto.Migration

  def change do
    alter table(:profiles) do
      add :environment_key, :string
    end

    create unique_index(:profiles, [:environment_key])
  end
end

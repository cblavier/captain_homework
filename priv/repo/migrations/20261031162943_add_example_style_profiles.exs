defmodule CaptainHomework.Repo.Migrations.AddExampleStyleProfiles do
  use Ecto.Migration

  def change do
    alter table(:pages) do
      add :style_profile, :map
      add :style_hash, :string
    end
  end
end

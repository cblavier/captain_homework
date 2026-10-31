defmodule CaptainHomework.Repo.Migrations.CreateSettings do
  use Ecto.Migration

  def change do
    create table(:settings, primary_key: false) do
      add :id, :integer, primary_key: true
      add :instructions, :text, null: false
      timestamps(type: :utc_datetime_usec)
    end
  end
end

defmodule CaptainHomework.Repo.Migrations.CreateExamShares do
  use Ecto.Migration

  def change do
    create table(:exam_shares, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :exam_id, references(:exams, type: :binary_id, on_delete: :delete_all), null: false
      add :token_hash, :binary, null: false
      add :mode, :string, null: false
      add :expires_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:exam_shares, [:token_hash])
    create index(:exam_shares, [:exam_id])
    create index(:exam_shares, [:expires_at])

    alter table(:exams) do
      add :exam_share_id, references(:exam_shares, type: :binary_id, on_delete: :delete_all)
      add :shared_visitor_hash, :binary
    end

    create unique_index(:exams, [:exam_share_id, :shared_visitor_hash])
  end
end

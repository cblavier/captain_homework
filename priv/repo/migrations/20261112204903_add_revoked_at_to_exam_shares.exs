defmodule CaptainHomework.Repo.Migrations.AddRevokedAtToExamShares do
  use Ecto.Migration

  def change do
    alter table(:exam_shares) do
      add :revoked_at, :utc_datetime_usec
    end
  end
end

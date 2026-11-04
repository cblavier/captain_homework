defmodule CaptainHomework.Repo.Migrations.TrackExtractedIllustrationSource do
  use Ecto.Migration

  def change do
    alter table(:pages) do
      # Keep the provenance after the original image is deleted.
      add :extracted_from_id, :binary_id
    end
  end
end

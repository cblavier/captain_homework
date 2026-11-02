defmodule CaptainHomework.Repo.Migrations.AddDocumentProcessingProgress do
  use Ecto.Migration

  def change do
    for table <- [:pages, :resources] do
      alter table(table) do
        add :processing_progress, :integer, default: 0, null: false
        add :processing_stage, :string
      end
    end
  end
end

defmodule CaptainHomework.Repo.Migrations.AddDocumentCatalogues do
  use Ecto.Migration

  def change do
    for table <- [:pages, :resources] do
      alter table(table) do
        add :catalogue, :map
        add :catalogue_hash, :string
      end
    end
  end
end

defmodule CaptainHomework.Repo.Migrations.AddFlashcardExams do
  use Ecto.Migration

  def change do
    alter table(:exams) do
      add :format, :string, null: false, default: "classic"
      add :card_index, :integer, null: false, default: 0
    end
  end
end

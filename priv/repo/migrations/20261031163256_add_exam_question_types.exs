defmodule CaptainHomework.Repo.Migrations.AddExamQuestionTypes do
  use Ecto.Migration

  def change do
    alter table(:exams) do
      add :question_types, :text,
        null: false,
        default: "[\"definition\",\"mcq\",\"cloze\",\"reading\",\"long\",\"diagram\"]"
    end
  end
end

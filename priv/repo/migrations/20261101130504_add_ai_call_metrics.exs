defmodule CaptainHomework.Repo.Migrations.AddAiCallMetrics do
  use Ecto.Migration

  def change do
    create table(:ai_calls) do
      add :exam_id, :binary_id
      add :stage, :string, null: false
      add :model, :string
      add :request_id, :string
      add :status, :string, null: false
      add :http_status, :integer
      add :duration_ms, :integer, null: false
      add :input_tokens, :integer
      add :output_tokens, :integer
      add :cached_tokens, :integer
      add :reasoning_tokens, :integer
      add :total_tokens, :integer
      add :image_count, :integer, null: false
      add :max_output_tokens, :integer
      add :incomplete_reason, :string
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:ai_calls, [:exam_id, :inserted_at])
    create index(:ai_calls, [:inserted_at])
  end
end

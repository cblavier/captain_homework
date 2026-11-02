defmodule CaptainHomework.AI.Call do
  @moduledoc "Metadata for one provider request. Prompts and responses are never stored here."
  use Ecto.Schema

  schema "ai_calls" do
    field :exam_id, Ecto.UUID
    field :stage, :string
    field :model, :string
    field :request_id, :string
    field :status, :string
    field :http_status, :integer
    field :duration_ms, :integer
    field :input_tokens, :integer
    field :output_tokens, :integer
    field :cached_tokens, :integer
    field :reasoning_tokens, :integer
    field :total_tokens, :integer
    field :image_count, :integer
    field :max_output_tokens, :integer
    field :incomplete_reason, :string
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end
end

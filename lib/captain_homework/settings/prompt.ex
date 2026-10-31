defmodule CaptainHomework.Settings.Prompt do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :integer, autogenerate: false}
  schema "settings" do
    field :instructions, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(prompt, attrs) do
    prompt
    |> cast(attrs, [:instructions])
    |> validate_required([:instructions], message: "Renseigne les instructions par défaut.")
    |> validate_length(:instructions,
      max: 16000,
      message: "Limite de 16 000 caractères dépassée."
    )
  end
end

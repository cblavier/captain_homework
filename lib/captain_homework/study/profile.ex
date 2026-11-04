defmodule CaptainHomework.Study.Profile do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "profiles" do
    field :name, :string
    field :disabled_subjects, {:array, :string}, default: []
    field :environment_key, :string
    field :school_name, :string, virtual: true
    field :class_name, :string, virtual: true
    field :avatar, :string, virtual: true
    field :theme, :string, virtual: true, default: "blue"
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(profile, attrs),
    do:
      profile
      |> cast(attrs, [:name])
      |> validate_required([:name])
      |> validate_length(:name, min: 1, max: 40)
end

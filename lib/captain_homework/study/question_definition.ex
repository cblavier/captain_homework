defmodule CaptainHomework.Study.QuestionDefinition do
  use Ecto.Schema
  import Ecto.Changeset
  alias CaptainHomework.{Study, WorkDuration}
  @primary_key {:id, :binary_id, autogenerate: true}
  @responses ~w(short_text long_text single_choice cloze legends photo recording photo_justification ordering)
  schema "question_definitions" do
    field :name, :string
    field :name_key, :string
    field :subjects, Study.JSONList, default: []
    field :modes, Study.JSONList, default: ["classic", "flashcard"]
    field :response_kind, :string, default: "short_text"
    field :instruction_kind, :string, default: "dynamic"
    field :instruction, :string
    field :content_kind, :string, default: "text"
    field :content_presence, :string, default: "optional"
    field :help_classic, :string
    field :help_flashcard, :string
    field :work_duration, :string, default: "quick"
    field :example, :map, default: %{}
    field :revision, :integer, default: 1
    field :deleted_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def response_options do
    Enum.zip(
      [
        "Texte court",
        "Texte long",
        "Choix unique",
        "Texte à trous",
        "Collection de légendes",
        "Photo",
        "Enregistrement vocal",
        "Photo avec justification",
        "Classement par clics"
      ],
      @responses
    )
  end

  def changeset(type, attrs) do
    type
    |> cast(attrs, [
      :name,
      :subjects,
      :modes,
      :response_kind,
      :instruction_kind,
      :instruction,
      :content_kind,
      :content_presence,
      :help_classic,
      :help_flashcard,
      :work_duration
    ])
    |> update_change(:name, &String.trim/1)
    |> update_change(:subjects, &Enum.uniq(Enum.reject(&1, fn v -> v == "" end)))
    |> update_change(:modes, &Enum.uniq(Enum.reject(&1, fn v -> v == "" end)))
    |> validate_required([
      :name,
      :subjects,
      :modes,
      :response_kind,
      :instruction_kind,
      :content_kind,
      :content_presence,
      :work_duration
    ])
    |> validate_length(:name, max: 80)
    |> validate_length(:instruction, max: 2000)
    |> validate_length(:help_classic, max: 1000)
    |> validate_length(:help_flashcard, max: 1000)
    |> validate_choices(:subjects, Study.subject_ids())
    |> validate_choices(:modes, ~w(classic flashcard))
    |> validate_inclusion(:response_kind, @responses)
    |> validate_inclusion(:instruction_kind, ~w(fixed dynamic))
    |> validate_inclusion(:content_kind, ~w(text image document audio))
    |> validate_inclusion(:content_presence, ~w(required optional none))
    |> validate_inclusion(:work_duration, WorkDuration.values())
    |> require_fixed_instruction()
    |> then(fn cs -> put_change(cs, :name_key, String.downcase(get_field(cs, :name) || "")) end)
    |> unique_constraint(:name_key,
      name: :question_definitions_name_key_index,
      message: "Ce nom existe déjà."
    )
  end

  defp validate_choices(cs, field, allowed) do
    validate_change(cs, field, fn key, values ->
      if values != [] and Enum.all?(values, &(&1 in allowed)),
        do: [],
        else: [{key, "Choisis au moins une valeur valide."}]
    end)
  end

  defp require_fixed_instruction(cs) do
    if get_field(cs, :instruction_kind) == "fixed",
      do: validate_required(cs, [:instruction]),
      else: cs
  end
end

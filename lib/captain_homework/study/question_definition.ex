defmodule CaptainHomework.Study.QuestionDefinition do
  use Ecto.Schema
  import Ecto.Changeset
  alias CaptainHomework.{Study, WorkDuration}
  @primary_key {:id, :binary_id, autogenerate: true}
  @responses ~w(short_text long_text single_choice cloze legends photo recording photo_justification ordering)
  @content_kinds ~w(text document image audio)
  schema "question_definitions" do
    field :name, :string
    field :name_key, :string
    field :subjects, Study.JSONList, default: []
    field :modes, Study.JSONList, default: ["classic", "flashcard"]
    field :response_kind, :string, default: "short_text"
    field :instruction_kind, :string, default: "dynamic"
    field :instruction, :string
    field :ai_instructions, :string
    field :content_kind, :string, default: "text"
    field :content_kinds, Study.JSONList
    field :content_presence, :string, default: "optional"
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
      :ai_instructions,
      :content_kind,
      :content_kinds,
      :content_presence,
      :work_duration,
      :example
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
    |> validate_length(:ai_instructions, max: 8000)
    |> validate_choices(:subjects, Study.subject_ids())
    |> validate_choices(:modes, ~w(classic flashcard))
    |> validate_inclusion(:response_kind, @responses)
    |> validate_inclusion(:instruction_kind, ~w(fixed dynamic))
    |> validate_inclusion(:content_kind, @content_kinds)
    |> validate_inclusion(:content_presence, ~w(required optional none))
    |> normalize_content_kinds(attrs)
    |> validate_inclusion(:work_duration, WorkDuration.values())
    |> require_fixed_instruction()
    |> then(fn cs -> put_change(cs, :name_key, String.downcase(get_field(cs, :name) || "")) end)
    |> unique_constraint(:name_key,
      name: :question_definitions_name_key_index,
      message: "Ce nom existe déjà."
    )
  end

  def content_options do
    Enum.zip(["Texte", "Document", "Illustration", "Audio"], @content_kinds)
  end

  def content_kinds(%{content_kinds: kinds}) when is_list(kinds), do: kinds
  def content_kinds(%{content_kind: kind}), do: List.wrap(kind)
  def content_kinds(%{"content_kinds" => kinds}) when is_list(kinds), do: kinds
  def content_kinds(type), do: List.wrap(type["content_kind"])

  defp normalize_content_kinds(cs, attrs) do
    legacy_write? =
      (Map.has_key?(attrs, :content_kind) or Map.has_key?(attrs, "content_kind")) and
        not (Map.has_key?(attrs, :content_kinds) or Map.has_key?(attrs, "content_kinds"))

    cs = if legacy_write?, do: put_change(cs, :content_kinds, nil), else: cs
    kinds = get_field(cs, :content_kinds)

    if is_list(kinds) do
      selected = kinds |> Enum.reject(&(&1 == "")) |> Enum.uniq()
      ordered = Enum.filter(@content_kinds, &(&1 in selected))
      no_content? = get_field(cs, :content_presence) == "none"
      unknown_kind? = length(selected) != length(ordered)
      mixed_audio? = "audio" in ordered and length(ordered) > 1

      cond do
        no_content? and (unknown_kind? or mixed_audio?) ->
          delete_change(cs, :content_kinds)

        unknown_kind? ->
          add_error(cs, :content_kinds, "Choisis des natures de contenu proposées.")

        mixed_audio? ->
          add_error(cs, :content_kinds, "Choisis l’audio seul pour une question d’écoute.")

        ordered == [] and not no_content? ->
          cs
          |> put_change(:content_kinds, [])
          |> add_error(:content_kinds, "Choisis au moins une nature de contenu.")

        match?([_], ordered) ->
          cs
          |> put_change(:content_kind, hd(ordered))
          |> put_change(:content_kinds, nil)

        true ->
          put_change(cs, :content_kinds, ordered)
      end
    else
      cs
    end
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

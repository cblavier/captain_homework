defmodule CaptainHomework.QuestionTemplates do
  @moduledoc "Literal substitutions in question text, without interpreting code or cloze markers."
  @languages %{
    "anglais" => "anglais",
    "espagnol" => "espagnol",
    "francais" => "français",
    "latin" => "latin"
  }
  @fields ~w(prompt text document support_text support_title answer rubric help options)

  def render(nil, _), do: nil

  def render(text, subject) when is_binary(text) do
    case @languages[subject] do
      nil -> text
      language -> Regex.replace(~r/(?<!\{)\{langue\}(?!\})/u, text, language)
    end
  end

  def question(question, subject) do
    Map.new(question, fn {key, value} ->
      {key, if(key in @fields, do: render_value(value, subject), else: value)}
    end)
    |> then(fn resolved ->
      if is_map(resolved["audio_script"]),
        do:
          Map.update!(
            resolved,
            "audio_script",
            &Map.update(&1, "text", nil, fn text -> render_value(text, subject) end)
          ),
        else: resolved
    end)
  end

  defp render_value(values, subject) when is_list(values),
    do: Enum.map(values, &render_value(&1, subject))

  defp render_value(value, subject) when is_binary(value), do: render(value, subject)
  defp render_value(value, _), do: value
end

defmodule CaptainHomework.Exams.Ordering do
  @moduledoc "Numbered choices and the order selected by the student."

  def numbers(options),
    do: options |> Enum.with_index(1) |> Enum.map(fn {_, n} -> to_string(n) end)

  def sequence(answer, options) when is_binary(answer) do
    allowed = numbers(options)

    answer
    |> String.split(~r/[\s,;→>\-]+/u, trim: true)
    |> Enum.filter(&(&1 in allowed))
    |> Enum.uniq()
  end

  def sequence(_, _), do: []

  def normalize(answer, options), do: answer |> sequence(options) |> Enum.join(", ")

  def update(answer, options, action) do
    selected = sequence(answer, options)

    case action do
      "undo" ->
        Enum.drop(selected, -1)

      "clear" ->
        []

      number ->
        if number in numbers(options) and number not in selected,
          do: selected ++ [number],
          else: selected
    end
    |> Enum.join(", ")
  end

  def valid_question?(question) do
    options = question["options"]
    expected = sequence(question["answer"], options)

    length(options) in 2..8 and
      Enum.all?(options, &(String.trim(&1) != "")) and Enum.uniq(options) == options and
      Enum.sort(expected) == Enum.sort(numbers(options)) and
      question["answer"] == Enum.join(expected, ", ") and
      question["slots"] == [] and is_nil(question["diagram"])
  end

  def example_options(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.map(&(String.replace(&1, ~r/^\s*\d+[.):\-]\s*/u, "") |> String.trim()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.take(8)
  end
end

defmodule CaptainHomework.Text do
  @moduledoc "French count labels shared by UI and progress messages."

  def plural(count, singular, plural) when is_number(count),
    do: if(abs(count) < 2, do: singular, else: plural)

  def count_label(count, singular, plural),
    do: "#{count} #{plural(count, singular, plural)}"
end

defmodule CaptainHomework.Exams.LessonPages do
  @moduledoc "Course page numbers matching the ordered pages shown in the Leçons tab."

  def numbers(pages) do
    pages
    |> Enum.filter(&(&1.kind == "lesson"))
    |> Enum.with_index(1)
    |> Map.new(fn {page, number} -> {page.id, number} end)
  end
end

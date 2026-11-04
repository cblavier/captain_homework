defmodule CaptainHomework.Exams.Sources do
  import Ecto.Query
  alias CaptainHomework.Repo
  alias CaptainHomework.Study.Page

  def for_exam(exam, profile_id) do
    ids =
      exam.questions
      |> Enum.flat_map(&source_ids/1)
      |> Enum.uniq()
      |> Enum.filter(&match?({:ok, _}, Ecto.UUID.cast(&1)))

    pages =
      Repo.all(
        from p in Page,
          join: l in assoc(p, :lesson),
          where:
            p.id in ^ids and l.profile_id == ^profile_id and
              (p.kind in ["lesson", "resource"] or
                 (p.kind == "illustration" and not is_nil(p.extracted_from_id))),
          preload: [:lesson, :resource]
      )
      |> Map.new(&{&1.id, &1})

    page_numbers = lesson_page_numbers(pages)

    Map.new(exam.questions, fn question ->
      sources =
        question
        |> source_ids()
        |> Enum.uniq()
        |> Enum.flat_map(fn id ->
          case pages[id] do
            nil -> []
            page -> [source(page, page_numbers)]
          end
        end)

      {question["id"], sources}
    end)
  end

  defp source_ids(question) do
    case question["source_page_ids"] do
      ids when is_list(ids) -> Enum.filter(ids, &is_binary/1)
      _ -> []
    end
  end

  defp lesson_page_numbers(pages) do
    lesson_ids =
      pages
      |> Map.values()
      |> Enum.filter(&(&1.kind == "lesson"))
      |> Enum.map(& &1.lesson_id)
      |> Enum.uniq()

    Repo.all(
      from p in Page,
        where: p.lesson_id in ^lesson_ids and p.kind == "lesson",
        order_by: [p.position, p.inserted_at, p.id],
        select: {p.lesson_id, p.id}
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn {_, ids} -> Enum.with_index(ids, 1) end)
    |> Map.new()
  end

  defp source(%{kind: "lesson"} = page, page_numbers) do
    %{
      label: "Leçon : #{page.lesson.title}",
      page_id: page.id,
      page_number: Map.fetch!(page_numbers, page.id),
      resource_id: nil
    }
  end

  defp source(page, _page_numbers) do
    title =
      if page.resource, do: page.resource.title || page.resource.filename, else: page.filename

    %{
      label: "Document : #{title} — #{page.filename}",
      page_id: page.id,
      page_number: nil,
      resource_id: if(page.resource && page.resource.storage_key, do: page.resource.id)
    }
  end
end

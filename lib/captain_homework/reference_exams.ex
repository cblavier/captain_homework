defmodule CaptainHomework.ReferenceExams do
  import Ecto.Query
  alias CaptainHomework.{Repo, Study}
  alias CaptainHomework.Study.{Page, ReferenceExam}

  def list(profile_id, subject) do
    Repo.all(
      from r in ReferenceExam,
        where: r.profile_id == ^profile_id and r.subject == ^subject,
        order_by: [desc: r.date, desc: r.inserted_at],
        preload: [pages: ^pages_query()]
    )
  end

  def get!(profile_id, id) do
    unless match?({:ok, _}, Ecto.UUID.cast(id)),
      do: raise(Ecto.NoResultsError, queryable: ReferenceExam)

    Repo.one!(from r in ReferenceExam, where: r.id == ^id and r.profile_id == ^profile_id)
    |> Repo.preload(pages: pages_query())
  end

  def create(profile, subject, attrs) do
    Study.subject!(subject)

    %ReferenceExam{profile_id: profile.id, subject: subject}
    |> ReferenceExam.changeset(attrs)
    |> Repo.insert()
  end

  def update(profile_id, id, attrs) do
    get!(profile_id, id) |> ReferenceExam.changeset(attrs) |> Repo.update()
  end

  def delete(profile_id, id) do
    reference = get!(profile_id, id)

    with {:ok, reference} <- Repo.delete(reference) do
      Enum.each(reference.pages, &File.rm(CaptainHomework.Uploads.path(&1.storage_key)))
      {:ok, reference}
    end
  end

  def add_page(reference, attrs) do
    Repo.transaction(fn ->
      last =
        Repo.one(
          from p in Page, where: p.reference_exam_id == ^reference.id, select: max(p.position)
        )

      %Page{reference_exam_id: reference.id, position: (last || -1) + 1}
      |> Page.changeset(Map.put(attrs, :kind, "example"))
      |> Repo.insert!()
    end)
  end

  def move_page(profile_id, id, page_id, direction) when direction in ["previous", "next"] do
    Repo.transaction(fn ->
      pages = get!(profile_id, id).pages
      index = Enum.find_index(pages, &(&1.id == page_id))
      if is_nil(index), do: Repo.rollback(:not_found)
      target = index + if(direction == "previous", do: -1, else: 1)

      if target >= 0 and target < length(pages) do
        neighbor = Enum.at(pages, target)
        selected = Enum.at(pages, index)

        pages
        |> List.replace_at(index, neighbor)
        |> List.replace_at(target, selected)
        |> Enum.with_index()
        |> Enum.each(fn {page, position} ->
          page |> Ecto.Changeset.change(position: position) |> Repo.update!()
        end)
      end
    end)
  end

  def selection(_profile_id, _subject, id, _format) when id in [nil, ""], do: {:ok, nil, []}
  def selection(_profile_id, _subject, _id, "flashcard"), do: {:ok, nil, []}

  def selection(profile_id, subject, id, _format) do
    reference = get!(profile_id, id)

    cond do
      reference.subject != subject ->
        {:error, "Choisis un contrôle de référence de cette matière."}

      reference.pages == [] ->
        {:error, "Ajoute au moins une page au contrôle de référence."}

      true ->
        {:ok, reference.id, reference.pages}
    end
  rescue
    Ecto.NoResultsError -> {:error, "Ce contrôle de référence n’est plus disponible."}
  end

  defp pages_query, do: from(p in Page, order_by: [p.position, p.inserted_at, p.id])
end

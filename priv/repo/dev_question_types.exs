# Run explicitly: MIX_ENV=dev mix run priv/repo/dev_question_types.exs
if Mix.env() != :dev, do: raise("Ce catalogue doit être installé uniquement en développement.")

alias CaptainHomework.{Repo, Study, SubjectQuestionTypes}

{:ok, counts} =
  Repo.transaction(fn ->
    for profile <- Repo.all(Study.Profile), subject <- Study.subjects() do
      {:ok, settings} = SubjectQuestionTypes.seed_catalogue(profile.id, subject.id)
      {profile.name, subject.name, length(settings.types)}
    end
  end)

Enum.each(counts, fn {name, subject, count} ->
  IO.puts("#{name} / #{subject} : #{count} types")
end)

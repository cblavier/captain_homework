# Run explicitly: MIX_ENV=dev mix run priv/repo/dev_question_types.exs
if Mix.env() != :dev, do: raise("Ce catalogue doit être installé uniquement en développement.")
{:ok, _} = CaptainHomework.QuestionDefinitions.seed!()
types = CaptainHomework.QuestionDefinitions.list()
IO.puts("Catalogue commun : #{length(types)} types de questions.")
for subject <- CaptainHomework.Study.subjects() do
  IO.puts("#{subject.name} : #{Enum.count(types, &(subject.id in &1.subjects))} types")
end

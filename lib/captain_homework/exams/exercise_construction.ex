defmodule CaptainHomework.Exams.ExerciseConstruction do
  @moduledoc "Builds independent exercise contracts with bounded concurrency and coordinator-owned checkpoints."
  alias CaptainHomework.AI.{ResourcePreflight, Trace, WorkLimiter}

  alias CaptainHomework.Exams.{
    BuildError,
    ExerciseDraft,
    ExerciseSpec,
    Illustrations,
    ValidatedExercise
  }

  def run(lesson, plan, kept, checkpoint, opts \\ []) do
    with {:ok, _, images, _} <-
           ResourcePreflight.prepare(
             lesson,
             plan["context"],
             [],
             [],
             kept,
             plan,
             custom_instructions?: String.trim(plan["custom_instructions"] || "") != ""
           ),
         context <- context(lesson, plan, images),
         {:ok, specs} <- load_specs(plan, context),
         {:ok, cached} <- cached_questions(specs, plan["built_questions"] || %{}, context) do
      pending = Enum.reject(specs, &Map.has_key?(cached, &1.id))
      trace = Trace.context()
      provider = Keyword.get(opts, :provider, CaptainHomework.AI.provider())
      plan = plan |> Map.put("built_questions", cached) |> Map.delete("build_error")

      {plan, errors} =
        pending
        |> batches()
        |> Task.async_stream(
          fn batch ->
            Trace.with_context(trace, fn -> build_batch(provider, batch, context) end)
          end,
          max_concurrency: 3,
          ordered: false,
          timeout: :infinity
        )
        |> Enum.reduce({plan, []}, fn
          {:ok, {:ok, questions, batch_errors}}, {current, errors} ->
            built =
              Map.merge(current["built_questions"], Map.new(questions, &{&1["plan_id"], &1}))

            updated = Map.put(current, "built_questions", built)
            checkpoint.(updated)
            {updated, errors ++ batch_errors}

          {:ok, {:error, reason}}, {current, errors} ->
            {current, errors ++ [reason]}

          {:exit, _}, {current, errors} ->
            {current,
             errors ++
               [
                 BuildError.new(
                   :construction_interrupted,
                   :construction,
                   "La rédaction a été interrompue. Les exercices déjà construits sont conservés.",
                   retryable?: true
                 )
               ]}
        end)

      case errors do
        [] ->
          questions = Enum.map(specs, &Map.fetch!(plan["built_questions"], &1.id))

          {:ok, questions,
           plan |> Map.put("questions", questions) |> Map.put("construction_pending", false)}

        [error | _] ->
          {:error, error}
      end
    end
  end

  defp context(lesson, plan, images) do
    sources = Illustrations.content_pages(lesson)

    sources =
      if is_list(plan["allowed_source_page_ids"]),
        do: Enum.filter(sources, &(&1.id in plan["allowed_source_page_ids"])),
        else: sources

    %{
      sources: sources,
      images: images,
      supports: plan["supports"],
      types: plan["types"],
      subject: lesson.subject
    }
  end

  defp load_specs(plan, context) do
    specs = plan["exercise_specs"] || %{}
    ids = Enum.map(plan["questions"], & &1["id"])

    if Enum.sort(Map.keys(specs)) == Enum.sort(ids) do
      Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, loaded} ->
        case ExerciseSpec.from_map(specs[id], context) do
          {:ok, spec} when spec.id == id -> {:cont, {:ok, loaded ++ [spec]}}
          {:error, _} = error -> {:halt, error}
          _ -> {:halt, invalid_contract()}
        end
      end)
    else
      invalid_contract()
    end
  end

  defp cached_questions(specs, cache, context) do
    Enum.reduce_while(specs, {:ok, %{}}, fn spec, {:ok, questions} ->
      cached = cache[spec.id]

      prompt =
        cond do
          is_map(cached) and cached["exercise_spec_hash"] == spec.hash -> cached["prompt"]
          is_binary(spec.initial_prompt) -> spec.initial_prompt
          true -> nil
        end

      if is_binary(prompt) do
        case build_question(
               spec,
               %{"spec_id" => spec.id, "spec_hash" => spec.hash, "prompt" => prompt},
               context
             ) do
          {:ok, question} -> {:cont, {:ok, Map.put(questions, spec.id, question)}}
          error -> {:halt, error}
        end
      else
        {:cont, {:ok, questions}}
      end
    end)
  end

  # Shared supports stay in one batch. Independent groups are packed up to three questions.
  defp batches(specs) do
    groups =
      specs
      |> Enum.group_by(fn spec ->
        if spec.question["support_id"] == "",
          do: {:question, spec.id},
          else: {:support, spec.question["support_id"]}
      end)
      |> Map.values()
      |> Enum.sort_by(&hd(&1).id)

    {batches, current} =
      Enum.reduce(groups, {[], []}, fn group, {batches, current} ->
        if current != [] and length(current) + length(group) > 3,
          do: {batches ++ [current], group},
          else: {batches, current ++ group}
      end)

    if current == [], do: batches, else: batches ++ [current]
  end

  defp build_batch(provider, specs, context) do
    image_ids = Enum.flat_map(specs, & &1.question["image_ids"]) |> MapSet.new()

    request_context =
      Map.update!(
        context,
        :images,
        &Enum.filter(&1, fn image -> MapSet.member?(image_ids, image.id) end)
      )

    with {:ok, %{"questions" => drafts}} <-
           WorkLimiter.run(fn -> provider.draft_exercises(specs, request_context) end),
         true <- is_map(drafts) do
      extra = Map.keys(drafts) -- Enum.map(specs, & &1.id)

      errors =
        if extra == [],
          do: [],
          else: [
            BuildError.new(
              :invalid_draft,
              :construction,
              "Des consignes non demandées ont été reçues.",
              details: %{"ids" => extra}
            )
          ]

      Enum.reduce(specs, {:ok, [], errors}, fn spec, {:ok, questions, errors} ->
        case build_question(spec, drafts[spec.id], context) do
          {:ok, question} -> {:ok, questions ++ [question], errors}
          {:error, error} -> {:ok, questions, errors ++ [error]}
        end
      end)
    else
      {:error, %BuildError{}} = error ->
        error

      {:error, reason} ->
        {:error,
         BuildError.new(:provider_unavailable, :construction, CaptainHomework.AI.message(reason),
           retryable?: true
         )}

      _ ->
        {:error,
         BuildError.new(
           :invalid_draft,
           :construction,
           "Les consignes reçues ne correspondent pas exactement aux exercices demandés."
         )}
    end
  rescue
    _ ->
      {:error,
       BuildError.new(
         :construction_interrupted,
         :construction,
         "La construction des exercices a été interrompue.",
         retryable?: true
       )}
  end

  defp build_question(spec, raw, context) do
    with {:ok, draft} <- ExerciseDraft.new(spec, raw),
         draft <- %{
           draft
           | prompt: CaptainHomework.QuestionTemplates.render(draft.prompt, context.subject)
         },
         {:ok, exercise} <- ExerciseDraft.build(spec, draft, context),
         do: {:ok, ValidatedExercise.to_question(exercise)}
  end

  defp invalid_contract,
    do:
      {:error,
       BuildError.new(
         :invalid_contract,
         :construction,
         "Le contrôle ne contient pas exactement un contrat par exercice."
       )}
end

defmodule CaptainHomework.Exams.Generation do
  import CaptainHomework.Text
  import Ecto.Query
  alias CaptainHomework.{AI, Repo, QuestionDefinitions}
  alias CaptainHomework.Study.Exam

  alias CaptainHomework.Exams.{
    AuditCache,
    BuildError,
    ExerciseConstruction,
    GenerationHistory,
    Illustrations,
    Instructions,
    Listening,
    Plan,
    RepairProgress
  }

  alias CaptainHomework.AI.Trace

  def identify(q) do
    id = Ecto.UUID.generate()
    q |> Map.put("id", id) |> Map.put("origin_id", q["origin_id"] || q["id"] || id)
  end

  def run(exam, lesson, pages, examples, opts) do
    Trace.with_exam(exam.id, fn ->
      Trace.with_progress(&request_progress(exam, opts, &1, &2), fn ->
        do_run(exam, lesson, pages, examples, opts)
      end)
    end)
  end

  defp do_run(exam, lesson, pages, examples, opts) do
    exam = track_history(exam, &GenerationHistory.initialize/1)

    if Illustrations.resources_pending?(lesson) or pages == [] or
         Enum.any?(pages, &(String.trim(&1.text) == "")) do
      finish(exam, ["Les pages de leçon doivent contenir du texte avant de reprendre."])
    else
      with {:ok, exam} <- prepare_plan(exam, lesson, pages, examples, opts) do
        feedback =
          if exam.generation_plan, do: exam.generation_plan["repair_feedback"] || "", else: ""

        attempt(exam, lesson, pages, examples, opts, 0, feedback)
      else
        {:error, reason, checkpoint} -> finish(checkpoint, [AI.message(reason)])
        {:error, reason} -> finish(exam, [AI.message(reason)])
      end
    end
  rescue
    _ ->
      # Reload the last checkpoint, so an interrupted request never loses accepted questions.
      finish_current(exam, [
        "La génération a été interrompue. Les questions prêtes sont conservées."
      ])
  catch
    {:effort_review_failed, reason} ->
      finish_current(exam, [AI.message(reason)])
  end

  defp prepare_plan(exam, lesson, pages, examples, opts) do
    needs_plan? =
      exam.format != "flashcard" and Plan.supported?() and
        (is_nil(exam.generation_plan) or
           not Plan.current?(exam.generation_plan, lesson, pages, examples) or
           (String.trim(exam.instructions) != "" and
              exam.generation_plan["instruction_priority_version"] != 1))

    if needs_plan? do
      progress(exam, opts, "Préparation du contrôle…")

      track_history(
        exam,
        &GenerationHistory.pending(&1, "writing", "Rédaction des questions en cours")
      )

      kept = Enum.map(exam.questions, &ensure_plan_id/1)

      with {:ok, plan, exam} <- request_plan(exam, lesson, pages, examples, kept, 1, opts) do
        plan =
          case Plan.ready_questions(plan) do
            {:ok, drafts} -> pending_plan(plan, drafts)
            :legacy -> plan
          end

        exam = persist(exam, generation_plan: plan, questions: kept)
        {:ok, track_history(exam, &GenerationHistory.plan(&1, plan))}
      end
    else
      exam = track_history(exam, &GenerationHistory.plan(&1, exam.generation_plan))
      prepare_review(exam)
    end
  end

  defp prepare_review(exam) do
    plan = exam.generation_plan

    if is_map(plan) and
         (plan["review_revision"] != AuditCache.revision() or
            not Map.has_key?(plan, "review_diagnostics")) and
         function_exported?(AI.provider(), :audit_response_effort_detailed, 2) and
         match?({:ok, _}, Plan.ready_questions(plan)) do
      case Plan.remaining(plan, exam.questions) do
        [] ->
          {:ok, exam}

        remaining ->
          # Paid drafts take precedence over their earlier version in the plan.
          pending = if audit_pending?(exam), do: plan["pending_drafts"] || [], else: []
          drafts = Enum.uniq_by(pending ++ remaining, &(&1["plan_id"] || &1["id"]))

          plan =
            plan
            |> Map.drop(~w(review_diagnostics audit_cache repair_progress repair_feedback))
            |> Map.put("review_revision", AuditCache.revision())
            |> Map.put("review_diagnostics", %{})
            |> pending_plan(drafts)

          {:ok, persist(exam, generation_plan: plan, generation_errors: [])}
      end
    else
      {:ok, exam}
    end
  end

  defp request_plan(exam, lesson, pages, examples, kept, repairs, opts) do
    provider = AI.provider()

    reuse? =
      Plan.rejected_current?(exam.generation_plan, lesson, pages, examples) and
        exam.generation_plan["request_signature"] == request_signature(exam) and
        function_exported?(provider, :repair_control_plan, 8)

    if reuse? do
      progress(exam, opts, "Correction des questions à revoir…")

      track_history(
        exam,
        &GenerationHistory.pending(&1, "repairing", "Correction des questions rejetées en cours")
      )
    end

    result =
      Trace.with_stage("planning", fn ->
        args = [
          lesson,
          pages,
          examples,
          exam.generation_target,
          Instructions.compose(
            CaptainHomework.QuestionTemplates.render(exam.instructions, lesson.subject),
            definition_instructions(exam, lesson.subject)
          ),
          kept,
          exam.question_types
        ]

        if reuse? do
          rejected = %{
            "plan" => exam.generation_plan["rejected_plan"],
            "reason" => exam.generation_plan["rejection_reason"]
          }

          apply(provider, :repair_control_plan, args ++ [rejected])
        else
          callback =
            if function_exported?(provider, :plan_exercises, 7),
              do: :plan_exercises,
              else: :plan_control

          apply(provider, callback, args)
        end
      end)

    case result do
      {:ok, plan} ->
        {:ok, plan, exam}

      {:error, {:invalid_plan, raw, reason}} ->
        rejected = %{
          "version" => Plan.version(),
          "source_fingerprint" => Plan.fingerprint(lesson, pages, examples),
          "request_signature" => request_signature(exam),
          "rejected_plan" => raw,
          "rejection_reason" => reason
        }

        checkpoint = persist(exam, generation_plan: rejected, questions: kept)
        checkpoint = track_rejected_plan(checkpoint, raw, lesson, pages)

        if repairs > 0 and function_exported?(provider, :repair_control_plan, 8) do
          request_plan(checkpoint, lesson, pages, examples, kept, repairs - 1, opts)
        else
          {:error, :invalid_plan, checkpoint}
        end

      {:error, %BuildError{} = reason} ->
        plan = Map.put(exam.generation_plan || %{}, "build_error", BuildError.to_map(reason))
        {:error, reason, persist(exam, generation_plan: plan)}

      {:error, reason} ->
        {:error, reason, exam}
    end
  end

  defp definition_instructions(exam, subject),
    do: exam |> QuestionDefinitions.for_exam() |> QuestionDefinitions.instructions(subject)

  defp request_signature(exam) do
    {Plan.version(), exam.generation_target, exam.question_types, exam.instructions}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp ensure_plan_id(question) do
    if is_binary(question["plan_id"]),
      do: question,
      else: Map.put(question, "plan_id", "kept-" <> question["id"])
  end

  defp pending_plan(plan, drafts) do
    plan
    |> Map.put("pending_drafts", drafts)
    |> Map.put("audit_pending", true)
  end

  defp audit_pending?(exam),
    do: is_map(exam.generation_plan) and exam.generation_plan["audit_pending"] == true

  defp attempt(exam, lesson, pages, examples, opts, round, feedback) do
    missing = exam.generation_target - length(exam.questions)

    cond do
      missing == 0 and not audit_pending?(exam) ->
        finish(exam, [])

      round == 4 ->
        finish(exam, exam.generation_errors)

      stalled?(exam) and not audit_pending?(exam) ->
        finish(exam, exam.generation_errors)

      true ->
        stage =
          if round == 0,
            do: "préparation",
            else: "ajustement de #{count_label(missing, "question", "questions")}"

        progress(
          exam,
          opts,
          "#{count_label(length(exam.questions), "question prête", "questions prêtes")} sur #{exam.generation_target} · #{stage}…"
        )

        allowed =
          if round == 3 and is_nil(exam.generation_plan) do
            simple = Enum.filter(exam.question_types, &(&1 in ["definition", "long"]))
            if simple == [], do: exam.question_types, else: simple
          else
            exam.question_types
          end

        guidance =
          feedback <>
            if(round == 3,
              do:
                "\nREPLI OBLIGATOIRE : simplifie les questions tout en respectant les types autorisés et les supports nécessaires.",
              else: ""
            ) <>
            "\nTYPES AUTORISÉS EXCLUSIVEMENT : #{Enum.join(allowed, ", ")}. " <>
            "Cette sélection prévaut sur la répartition des exemples et les autres consignes de variété. " <>
            "Aucun type décoché ne doit apparaître ; tous les types cochés ne sont pas obligatoires."

        instructions =
          Instructions.compose(
            CaptainHomework.QuestionTemplates.render(exam.instructions, lesson.subject),
            definition_instructions(exam, lesson.subject) <> "\n" <> guidance
          )

        if is_nil(exam.generation_plan) do
          track_history(
            exam,
            &GenerationHistory.pending(
              &1,
              "writing",
              "Rédaction des questions manquantes en cours"
            )
          )
        end

        result =
          cond do
            exam.format == "flashcard" ->
              Trace.with_stage("draft", fn ->
                AI.provider().generate_flashcards(
                  lesson,
                  pages,
                  missing,
                  instructions,
                  exam.questions,
                  allowed
                )
              end)
              |> with_plan(nil)

            is_map(exam.generation_plan) and exam.generation_plan["construction_pending"] == true ->
              construct_exercises(exam, lesson)

            audit_pending?(exam) ->
              {:ok, exam.generation_plan["pending_drafts"], exam.generation_plan}

            exam.generation_plan ->
              slots = Plan.remaining(exam.generation_plan, exam.questions)
              repair_candidates(exam, lesson, slots, instructions)

            true ->
              Trace.with_stage("draft", fn ->
                AI.generate(lesson, pages, examples, missing, instructions, exam.questions)
              end)
              |> with_plan(nil)
          end

        case result do
          {:ok, candidates, plan} ->
            # Persist paid drafts before the reviewer call. A failed/slow review can resume here.
            exam =
              if plan && not audit_pending?(exam) do
                persist(exam, generation_plan: pending_plan(plan, candidates))
              else
                exam
              end

            candidates =
              Enum.map(
                candidates,
                &render_question(&1, lesson.subject)
              )

            candidates = GenerationHistory.identify_drafts(Repo.get!(Exam, exam.id), candidates)
            track_history(exam, &GenerationHistory.received(&1, candidates))

            {audit_kept, candidates} = merge_drafts(exam.questions, candidates)

            {valid, errors, local_diagnostics} =
              validate_candidates(candidates, audit_kept, allowed, exam, lesson, pages)

            track_history(exam, &GenerationHistory.rejected(&1, local_diagnostics))

            progress(
              exam,
              opts,
              "Préparation des documents à vérifier…"
            )

            {review_input, refreshed_image_errors, refreshed_diagnostics} =
              validate_refreshed_images(
                refresh_supports(audit_kept, exam.generation_plan) ++ valid,
                lesson
              )

            track_history(exam, &GenerationHistory.rejected(&1, refreshed_diagnostics))

            {reviewed, effort_errors, diagnostics, cache} =
              audit_effort(review_input, exam, lesson)

            kept_ids = MapSet.new(exam.questions, & &1["id"])
            {kept, valid} = Enum.split_with(reviewed, &MapSet.member?(kept_ids, &1["id"]))
            errors = errors ++ effort_errors
            errors = errors ++ refreshed_image_errors
            {accepted, errors} = accept_unique(valid, kept, errors, allowed)
            accepted = Enum.take(accepted, exam.generation_target - length(kept))

            track_history(exam, &GenerationHistory.rejected(&1, diagnostics))
            track_unexplained_rejections(exam, review_input, kept ++ accepted, diagnostics)

            if Enum.any?(accepted, &(&1["type"] == "listening")),
              do: progress(exam, opts, "Création des extraits audio…")

            audio_candidates = accepted

            track_history(
              exam,
              &GenerationHistory.transition(
                &1,
                Enum.filter(accepted, fn q -> q["type"] == "listening" end),
                "waiting",
                "En attente de création de l’extrait audio"
              )
            )

            {accepted, audio_errors} =
              Listening.prepare(accepted, fn question ->
                track_history(
                  exam,
                  &GenerationHistory.transition(
                    &1,
                    [question],
                    "audio",
                    "Création de l’extrait audio"
                  )
                )
              end)

            errors = errors ++ audio_errors

            if audio_errors != [] do
              unfinished =
                Enum.reject(audio_candidates, fn q ->
                  Enum.any?(accepted, &(GenerationHistory.key(&1) == GenerationHistory.key(q)))
                end)

              # Listening.prepare stops at the first failure; later questions have not failed.
              [failed | waiting] = unfinished

              track_history(exam, fn current ->
                current
                |> GenerationHistory.transition(
                  [failed],
                  "interrupted",
                  Enum.join(audio_errors, " ")
                )
                |> GenerationHistory.transition(
                  waiting,
                  "waiting",
                  "En attente après l’interruption de la création audio"
                )
              end)
            end

            definitions = QuestionDefinitions.for_exam(exam)

            accepted =
              Enum.map(accepted, fn q ->
                helps =
                  definitions
                  |> Enum.filter(&(QuestionDefinitions.engine_format(&1) == q["type"]))
                  |> Enum.map(fn type ->
                    if exam.format == "flashcard",
                      do: type.help_flashcard,
                      else: type.help_classic
                  end)
                  |> Enum.uniq()

                q =
                  case helps do
                    [help] ->
                      Map.put(
                        q,
                        "help",
                        CaptainHomework.QuestionTemplates.render(help, lesson.subject)
                      )

                    _ ->
                      q
                  end

                render_question(q, lesson.subject)
              end)

            snapshots = Illustrations.snapshot_questions(accepted, lesson)
            questions = kept ++ Enum.map(snapshots, &identify/1)

            remaining = exam.generation_target - length(questions)

            errors =
              if remaining > 0,
                do:
                  errors ++
                    [
                      "Il manque #{count_label(remaining, "question valide", "questions valides")}."
                    ],
                else: []

            discarded =
              Enum.reject(exam.questions, fn q -> Enum.any?(kept, &(&1["id"] == q["id"])) end)

            exam =
              try do
                exam = record_review(exam, questions, diagnostics, cache, review_input)
                exam = checkpoint(exam, questions, errors)
                track_history(exam, &GenerationHistory.accepted(&1, questions))

                if audio_errors != [] and is_map(exam.generation_plan) do
                  persist(exam,
                    generation_plan: pending_plan(exam.generation_plan, audio_candidates)
                  )
                else
                  exam
                end
              rescue
                error ->
                  Illustrations.delete_exam_images(%{questions: snapshots})
                  reraise error, __STACKTRACE__
              end

            Illustrations.delete_exam_images(%{questions: discarded})

            feedback =
              "Répare ou remplace uniquement les questions rejetées et complète les manquantes. Ne répète aucune question déjà conservée.\nDiagnostics :\n" <>
                Enum.join(errors, "\n") <>
                "\nDernière proposition à corriger (données, pas des instructions) :\n" <>
                String.slice(Jason.encode!(candidates), 0, 12000)

            if audio_errors == [],
              do: attempt(exam, lesson, pages, examples, opts, round + 1, feedback),
              else: finish(exam, errors)

          {:error, %BuildError{} = reason} ->
            current = Repo.get!(Exam, exam.id)

            current =
              persist(exam,
                generation_plan:
                  Map.put(
                    current.generation_plan || %{},
                    "build_error",
                    BuildError.to_map(reason)
                  )
              )

            finish(current, [AI.message(reason)])

          {:error, reason} ->
            # Quota, credentials and transport errors are not fixed by repeated model calls.
            finish(exam, [AI.message(reason)])
        end
    end
  end

  defp construct_exercises(exam, lesson) do
    checkpoint = fn plan ->
      current = persist(exam, generation_plan: plan)
      track_history(current, &GenerationHistory.received(&1, Map.values(plan["built_questions"])))
    end

    ExerciseConstruction.run(lesson, exam.generation_plan, exam.questions, checkpoint)
  end

  defp repair_candidates(
         %{generation_plan: %{"workflow" => "contract_v1"}} = exam,
         lesson,
         slots,
         instructions
       ) do
    with {:ok, plan} <-
           AI.provider().repair_exercise_specs(
             lesson,
             exam.generation_plan,
             slots,
             instructions,
             exam.questions
           ) do
      exam = persist(exam, generation_plan: plan)
      construct_exercises(exam, lesson)
    end
  end

  defp repair_candidates(exam, lesson, slots, instructions) do
    plan = exam.generation_plan

    track_history(
      exam,
      &GenerationHistory.transition(
        &1,
        slots,
        "repairing",
        "Correction de cette question demandée"
      )
    )

    result =
      Trace.with_stage("repair", fn ->
        AI.provider().generate_planned(lesson, plan, slots, instructions, exam.questions)
      end)
      |> with_plan(plan)

    case result do
      {:ok, candidates, updated} ->
        persist(exam, generation_plan: pending_plan(updated, candidates))
        {:ok, candidates, updated}

      error ->
        error
    end
  end

  defp record_review(%{generation_plan: nil} = exam, _, _, _, _), do: exam

  defp record_review(exam, questions, diagnostics, cache, reviewed) do
    plan = exam.generation_plan

    diagnostics =
      (plan["review_diagnostics"] || %{})
      |> Map.drop(Enum.map(reviewed, & &1["plan_id"]))
      |> Map.merge(diagnostics)

    progress =
      RepairProgress.update(plan["repair_progress"] || %{}, length(questions), diagnostics)

    plan =
      plan
      |> Map.put("audit_cache", cache)
      |> Map.put("review_revision", AuditCache.revision())
      |> Map.put("review_diagnostics", diagnostics)
      |> Map.put("repair_progress", progress)

    %{exam | generation_plan: plan}
  end

  defp stalled?(exam) do
    is_map(exam.generation_plan) and
      function_exported?(AI.provider(), :audit_response_effort_detailed, 2) and
      RepairProgress.stalled?(exam.generation_plan["repair_progress"] || %{})
  end

  defp validate_refreshed_images(questions, lesson) do
    Enum.reduce(questions, {[], [], %{}}, fn question, {accepted, errors, diagnostics} ->
      case Illustrations.validate([question], lesson, allow_snapshots: true) do
        {[_], []} ->
          {accepted ++ [question], errors, diagnostics}

        {[], reasons} ->
          {accepted, errors ++ reasons,
           Map.put(diagnostics, GenerationHistory.key(question), reasons)}
      end
    end)
  end

  defp merge_drafts(kept, drafts) do
    Enum.reduce(kept, {[], drafts}, fn question, {retained, remaining} ->
      draft =
        Enum.find(remaining, &(is_binary(&1["plan_id"]) and &1["plan_id"] == question["plan_id"]))

      cond do
        is_nil(draft) ->
          {retained ++ [question], remaining}

        comparable_content(draft) == comparable_content(question) ->
          # Keep persisted IDs and image files, but adopt the newly checked plan metadata.
          updated =
            Map.merge(
              question,
              Map.take(
                draft,
                ~w(objective skill response_effort answer_basis expected_elements source_page_ids support_id exercise_spec_id exercise_spec_hash exercise_spec_version structural_validation pedagogical_audit)
              )
            )

          {retained ++ [updated], List.delete(remaining, draft)}

        true ->
          {retained, remaining}
      end
    end)
  end

  defp comparable_content(question) do
    defaults = %{
      "audio_script" => nil,
      "image_ids" => [],
      "image_regions" => [],
      "options" => [],
      "slots" => [],
      "diagram" => nil,
      "text" => "",
      "support_text" => ""
    }

    Map.new(
      ~w(type prompt text audio_script options slots diagram answer rubric points image_ids image_regions support_text),
      &{&1, Map.get(question, &1, defaults[&1])}
    )
  end

  defp refresh_supports(questions, nil), do: questions

  defp refresh_supports(questions, plan) do
    Enum.map(questions, fn question ->
      case Plan.attach(question, plan["questions"], plan["supports"]) do
        {:ok, updated} ->
          if Map.take(comparable_content(updated), [
               "text",
               "image_ids",
               "image_regions",
               "support_text"
             ]) ==
               Map.take(comparable_content(question), [
                 "text",
                 "image_ids",
                 "image_regions",
                 "support_text"
               ]) do
            updated
          else
            # A repaired shared support needs a new validated image snapshot.
            Map.drop(updated, ["id", "images"])
          end

        :error ->
          question
      end
    end)
  end

  defp with_plan({:ok, candidates}, plan), do: {:ok, candidates, plan}
  defp with_plan(result, _plan), do: result

  defp render_question(%{"exercise_spec_hash" => _} = question, _subject), do: question

  defp render_question(question, subject),
    do: CaptainHomework.QuestionTemplates.question(question, subject)

  defp audit_effort(questions, exam, lesson) do
    provider = AI.provider()

    if function_exported?(provider, :audit_response_effort, 2) do
      plan = exam.generation_plan || %{}

      supports = Map.get(plan, "supports", [])

      visible_ids =
        Enum.uniq(
          Enum.flat_map(questions, &Map.get(&1, "image_ids", [])) ++
            Enum.flat_map(supports, &Map.get(&1, "image_ids", []))
        )

      source_ids = Enum.uniq(Enum.flat_map(questions, &Map.get(&1, "source_page_ids", [])))

      context = %{
        subject: lesson.subject,
        lesson_title: lesson.title,
        custom_instructions: exam.instructions,
        permitted_content: plan["context"],
        supports: supports,
        images:
          Enum.filter(
            CaptainHomework.AI.ResourcePreflight.available_images(lesson, questions),
            &(&1.id in visible_ids)
          ),
        source_pages: Enum.filter(Illustrations.content_pages(lesson), &(&1.id in source_ids))
      }

      if function_exported?(provider, :audit_response_effort_detailed, 2) do
        scope = {plan["source_fingerprint"], exam.instructions, exam.question_types}

        {targets, exposure, retained} =
          AuditCache.select(questions, plan["audit_cache"] || %{}, scope)

        track_history(
          exam,
          &GenerationHistory.transition(
            &1,
            targets,
            "checking",
            "Vérification de la consigne, du support et du barème"
          )
        )

        track_history(
          exam,
          &GenerationHistory.transition(
            &1,
            exposure,
            "checking",
            "Vérification qu’aucun autre document ne dévoile la réponse"
          )
        )

        context =
          Map.merge(context, %{retained_questions: retained, exposure_only_questions: exposure})

        result =
          if targets == [] and exposure == [] do
            {:ok, [], [], %{}}
          else
            Trace.with_stage("audit", fn ->
              provider.audit_response_effort_detailed(targets, context)
            end)
          end

        case result do
          {:ok, accepted, errors, diagnostics} ->
            accepted = Enum.map(accepted ++ retained, &record_pedagogical_validation/1)
            {accepted, errors, diagnostics, AuditCache.record(accepted, questions, scope)}

          {:error, reason} ->
            throw({:effort_review_failed, reason})
        end
      else
        track_history(
          exam,
          &GenerationHistory.transition(
            &1,
            questions,
            "checking",
            "Vérification de la consigne, du support et du barème"
          )
        )

        case Trace.with_stage("audit", fn ->
               provider.audit_response_effort(questions, context)
             end) do
          {:ok, accepted, errors} ->
            {Enum.map(accepted, &record_pedagogical_validation/1), errors, %{}, %{}}

          {:error, reason} ->
            throw({:effort_review_failed, reason})
        end
      end
    else
      {questions, [], %{}, %{}}
    end
  end

  defp record_pedagogical_validation(%{"exercise_spec_hash" => _} = question),
    do: Map.put(question, "pedagogical_audit", "accepted")

  defp record_pedagogical_validation(question), do: question

  defp accept_unique(candidates, kept, errors, allowed) do
    Enum.reduce(candidates, {[], errors}, fn q, {accepted, errors} ->
      cond do
        q["type"] not in allowed ->
          {accepted,
           errors ++
             [
               "Type non autorisé : #{q["type"]}. Utilise uniquement #{Enum.join(allowed, ", ")}. "
             ]}

        Enum.any?(
          kept ++ accepted,
          &(fingerprint(&1) == fingerprint(q) or Plan.duplicate?(&1, q))
        ) ->
          {accepted, errors ++ ["Une question répète un énoncé déjà conservé."]}

        true ->
          {accepted ++ [q], errors}
      end
    end)
  end

  defp fingerprint(q) do
    # The prompt can be a shared heading; the actual question may be in text.
    text =
      Enum.map(~w(prompt text), fn field ->
        q[field] |> String.downcase() |> String.replace(~r/\s+/, " ") |> String.trim()
      end)

    {text, Plan.visual_identity(q), Enum.sort(q["options"] || [])}
  end

  defp checkpoint(exam, questions, errors) do
    plan =
      if exam.generation_plan do
        exam.generation_plan
        |> Plan.sync_review(questions)
        |> Map.delete("pending_drafts")
        |> Map.put("audit_pending", false)
        |> Map.put("repair_feedback", Enum.join(errors, "\n"))
      end

    persist(exam, questions: questions, generation_errors: errors, generation_plan: plan)
  end

  defp finish_current(exam, errors) do
    case Repo.get(Exam, exam.id) do
      %{status: "generating", generation_started_at: started} = current
      when started == exam.generation_started_at ->
        finish(current, errors)

      nil ->
        {:error, :deleted}

      current ->
        {:ok, current}
    end
  end

  defp complete_plan?(%{generation_plan: %{"rejected_plan" => _}}), do: false

  defp complete_plan?(%{
         generation_plan: %{"version" => version, "questions" => slots},
         questions: questions
       })
       when version >= 3 do
    ids = Enum.map(questions, & &1["plan_id"])
    expected = Enum.map(slots, & &1["id"])

    length(Enum.uniq(ids)) == length(ids) and Enum.sort(ids) == Enum.sort(expected) and
      Enum.all?(~w(response_effort answer_basis), fn key ->
        Enum.frequencies_by(questions, & &1[key]) == Enum.frequencies_by(slots, & &1[key])
      end)
  end

  defp complete_plan?(_), do: true

  defp finish(exam, errors) do
    complete? =
      length(exam.questions) == exam.generation_target and not audit_pending?(exam) and
        complete_plan?(exam)

    message =
      cond do
        complete? ->
          nil

        is_map(exam.generation_plan) and is_map(exam.generation_plan["build_error"]) ->
          exam.generation_plan["build_error"]["message"]

        stalled?(exam) ->
          "La génération est arrêtée : les dernières corrections n’améliorent plus les questions restantes. #{count_label(length(exam.questions), "question prête conservée", "questions prêtes conservées")}."

        true ->
          "#{count_label(length(exam.questions), "question prête", "questions prêtes")} sur #{exam.generation_target}. " <>
            "Le travail effectué est conservé ; réessaie uniquement les questions manquantes."
      end

    unless complete? do
      track_history(exam, &GenerationHistory.stopped(&1, Enum.join(public_errors(errors), " ")))
    end

    exam =
      persist(exam,
        status: if(complete?, do: "in_progress", else: "generation_partial"),
        error: message,
        generation_errors: if(complete?, do: [], else: public_errors(errors)),
        generation_stage: nil,
        questions: Plan.order(exam.questions, exam.generation_plan),
        generation_duration_ms:
          (Map.get(exam, :generation_duration_ms) || 0) +
            max(DateTime.diff(DateTime.utc_now(), exam.generation_started_at, :millisecond), 0)
      )

    notify_finished(exam)
    {:ok, exam}
  end

  def public_errors(errors) do
    errors
    |> Enum.map(fn error ->
      if String.contains?(error, "effort constaté") do
        "Certaines questions présentent encore une incohérence entre leur consigne, leur support et leur réponse attendue. Réessaie les questions manquantes."
      else
        error
      end
    end)
    |> Enum.uniq()
  end

  defp persist(exam, attrs) do
    {1, _} =
      Repo.update_all(
        from(e in Exam,
          where:
            e.id == ^exam.id and e.status == "generating" and
              e.generation_started_at == ^exam.generation_started_at
        ),
        set: attrs ++ [updated_at: DateTime.utc_now()]
      )

    notify(exam)
    Repo.get!(Exam, exam.id)
  end

  defp track_history(exam, update) do
    current = Repo.get!(Exam, exam.id)
    updated = update.(current)

    if updated.generation_history == current.generation_history,
      do: current,
      else: persist(exam, generation_history: updated.generation_history)
  end

  defp validate_candidates(candidates, kept, allowed, exam, lesson, pages) do
    Enum.reduce(candidates, {[], [], %{}}, fn q, {accepted, errors, diagnostics} ->
      reasons = AI.question_errors(q)
      valid = if reasons == [], do: [q], else: []

      {valid, flashcard_errors} =
        if exam.format == "flashcard",
          do: CaptainHomework.Exams.Flashcards.validate_candidates(valid, pages),
          else: {valid, []}

      {valid, image_errors} = Illustrations.validate(valid, lesson)

      {valid, reasons} =
        accept_unique(
          valid,
          kept ++ accepted,
          reasons ++ flashcard_errors ++ image_errors,
          allowed
        )

      diagnostics =
        if reasons == [],
          do: diagnostics,
          else: Map.put(diagnostics, GenerationHistory.key(q), reasons)

      {accepted ++ valid, errors ++ reasons, diagnostics}
    end)
  end

  defp track_unexplained_rejections(exam, reviewed, accepted, diagnostics) do
    rejected =
      Enum.reject(reviewed, fn q ->
        Map.has_key?(diagnostics, q["plan_id"]) or
          Enum.any?(accepted, &(GenerationHistory.key(&1) == GenerationHistory.key(q)))
      end)

    track_history(
      exam,
      &GenerationHistory.transition(
        &1,
        rejected,
        "rejected",
        "Question écartée lors de la vérification ; aucun diagnostic individuel fourni."
      )
    )
  end

  defp track_rejected_plan(exam, raw, lesson, pages) do
    questions = if is_map(raw), do: Enum.filter(List.wrap(raw["questions"]), &is_map/1), else: []
    ids = Enum.map(questions, & &1["id"])

    diagnostics =
      Plan.diagnostics(raw, ids, exam.question_types, pages, Illustrations.sources(lesson))

    track_history(exam, fn current ->
      current
      |> GenerationHistory.plan(raw)
      |> GenerationHistory.received(Enum.map(questions, &Map.put(&1, "plan_id", &1["id"])))
      |> GenerationHistory.rejected(diagnostics)
    end)
  rescue
    # Malformed provider output must not prevent the existing plan repair/recovery path.
    _ -> exam
  end

  def interrupt(exam, reason, elapsed_ms \\ nil) do
    current = Repo.get(Exam, exam.id)

    history =
      if current, do: GenerationHistory.stopped(current, reason).generation_history, else: []

    duration =
      if is_integer(elapsed_ms),
        do: [
          generation_duration_ms:
            (Map.get(exam, :generation_duration_ms) || 0) + max(elapsed_ms, 0)
        ],
        else: []

    {changed, _} =
      Repo.update_all(
        from(e in Exam,
          where:
            e.id == ^exam.id and e.status == "generating" and
              e.generation_started_at == ^exam.generation_started_at
        ),
        set:
          [
            status: "generation_partial",
            error: reason,
            generation_errors: [reason],
            generation_history: history,
            generation_stage: nil,
            updated_at: DateTime.utc_now()
          ] ++ duration
      )

    if changed > 0 do
      notify(exam)
      notify_finished(Repo.get!(Exam, exam.id))
    end

    :ok
  end

  defp request_progress(exam, opts, stage, count) do
    current = Repo.get!(Exam, exam.id)
    missing = max(exam.generation_target - length(current.questions), 1)
    count = count || missing
    questions = count_label(count, "question", "questions")

    message =
      case stage do
        "catalogue" -> "Analyse des ressources…"
        "selection" -> "Sélection des contenus…"
        "planning" -> "Rédaction des questions…"
        "instructions" -> "Vérification de la compatibilité des consignes…"
        "specification" -> "Préparation des contrats des exercices…"
        "repair_specification" -> "Révision des contrats à corriger…"
        "construction" -> "Rédaction des consignes des exercices…"
        "draft" -> "Rédaction de #{questions}…"
        "repair" -> "Ajustement de #{questions}…"
        "audit" -> "Vérification des questions modifiées et de leurs documents…"
        _ -> "Préparation du contrôle…"
      end

    progress(exam, opts, message)
  end

  defp progress(exam, opts, message) do
    Repo.update_all(
      from(e in Exam,
        where:
          e.id == ^exam.id and e.status == "generating" and
            e.generation_started_at == ^exam.generation_started_at
      ),
      set: [generation_stage: message, updated_at: DateTime.utc_now()]
    )

    notify(exam)
    Keyword.get(opts, :progress, fn _ -> :ok end).(message)
  end

  defp notify(exam) do
    Phoenix.PubSub.broadcast(CaptainHomework.PubSub, "exam:#{exam.id}", :exam_updated)
    Phoenix.PubSub.broadcast(CaptainHomework.PubSub, "lesson:#{exam.lesson_id}", :lesson_updated)
  end

  defp notify_finished(exam) do
    Phoenix.PubSub.broadcast(
      CaptainHomework.PubSub,
      "exam_generation",
      {:exam_generation_finished,
       Map.take(exam, [:id, :lesson_id, :status, :generation_started_at])}
    )
  end
end

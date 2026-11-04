defmodule CaptainHomework.Exams.Plan do
  @skills ~w(recall explain chronology locate interpret identify_source justify)
  def skills, do: @skills

  def supported? do
    provider = CaptainHomework.AI.provider()

    Code.ensure_loaded?(provider) and function_exported?(provider, :plan_control, 7) and
      function_exported?(provider, :generate_planned, 5)
  end

  def validate(plan, count, types, pages, images, opts \\ [])

  def validate(
        %{"questions" => questions, "supports" => supports},
        count,
        types,
        pages,
        images,
        opts
      )
      when is_list(questions) and is_list(supports) do
    sources = MapSet.new(pages, & &1.id)
    image_ids = MapSet.new(images, & &1.id)
    support_ids = Enum.map(supports, & &1["id"])

    valid_supports =
      length(supports) <= count and unique?(support_ids) and
        Enum.all?(supports, fn s ->
          text?(s["id"], 100) and text?(s["title"], 200) and
            is_binary(s["text"]) and byte_size(s["text"]) <= 20_000 and
            ids?(s["image_ids"], image_ids) and
            (String.trim(s["text"]) != "" or s["image_ids"] != [])
        end)

    valid_questions =
      length(questions) == count and unique?(Enum.map(questions, & &1["id"])) and
        Enum.all?(questions, fn q ->
          text?(q["id"], 100) and q["type"] in types and text?(q["objective"], 1000) and
            q["skill"] in @skills and
            (not Map.has_key?(q, "response_effort") or
               q["response_effort"] in ~w(direct short developed)) and
            is_list(q["expected_elements"]) and length(q["expected_elements"]) in 1..12 and
            Enum.all?(q["expected_elements"], &text?(&1, 1000)) and
            ids?(q["source_page_ids"], sources) and q["source_page_ids"] != [] and
            (not Map.has_key?(q, "planned_image_ids") or ids?(q["planned_image_ids"], image_ids)) and
            (q["support_id"] == "" or q["support_id"] in support_ids) and
            (q["type"] not in ["cloze", "diagram", "listening"] or q["support_id"] == "")
        end)

    if valid_supports and valid_questions do
      issues =
        (CaptainHomework.Exams.AnswerBasis.validation_errors(questions, pages, types, opts) ++
           Enum.flat_map(supports ++ questions, &region_errors/1))
        |> issue(
          not unique?(
            Enum.map(questions, &{normalize(&1["objective"]), &1["skill"], visual_identity(&1)})
          ),
          "Une notion est évaluée plusieurs fois avec la même compétence."
        )
        |> issue(
          not unique?(
            Enum.map(
              questions,
              &{Enum.sort(Enum.map(&1["expected_elements"], fn e -> normalize(e) end)),
               &1["skill"], visual_identity(&1)}
            )
          ),
          "Deux questions attendent les mêmes éléments de réponse pour la même compétence."
        )
        |> issue(
          Enum.any?(questions, fn q ->
            Enum.any?(q["expected_elements"], &Regex.match?(~r/^[0-9]{1,2}$/, String.trim(&1)))
          end),
          "Les éléments attendus doivent décrire les faits évalués, pas seulement des numéros de réponse."
        )

      # A matching term in another support does not establish that it gives away
      # the answer. Pedagogical leakage is assessed in the generation prompt.
      if issues == [], do: :ok, else: {:error, Enum.join(issues, " ")}
    else
      {:error,
       "Le plan contient des supports incomplets, des types non autorisés ou des références invalides. Vérifie les identifiants, le nombre exact de questions et les supports (vides pour cloze/diagram)."}
    end
  rescue
    _ -> {:error, "Le plan contient une structure de question ou de support invalide."}
  end

  def validate(_, _, _, _, _, _), do: {:error, "Le plan du contrôle est incomplet."}

  @version 4
  def version, do: @version

  def fingerprint(lesson, pages, examples) do
    {@version, lesson.subject, lesson.title,
     pages
     |> Enum.sort_by(& &1.id)
     |> Enum.map(
       &Map.take(&1, [:id, :text, :storage_key, :kind, :resource_id, :position, :content_type])
     ),
     examples
     |> Enum.sort_by(& &1.id)
     |> Enum.map(&Map.take(&1, [:id, :storage_key, :position, :content_type]))}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def current?(plan, lesson, pages, examples),
    do:
      is_map(plan) and not Map.has_key?(plan, "rejected_plan") and plan["version"] == @version and
        plan["source_fingerprint"] == fingerprint(lesson, pages, examples)

  def rejected_current?(plan, lesson, pages, examples),
    do:
      is_map(plan) and is_map(plan["rejected_plan"]) and plan["version"] == @version and
        plan["source_fingerprint"] == fingerprint(lesson, pages, examples)

  def ready_questions(%{"rejected_plan" => _}), do: :legacy
  def ready_questions(%{"construction_pending" => true}), do: :legacy
  def ready_questions(%{"version" => @version} = plan), do: {:ok, plan["questions"]}
  def ready_questions(_), do: :legacy

  def validate_complete(plan, count, types, pages, images, ids \\ nil, opts \\ []) do
    with :ok <- validate(plan, count, types, pages, images, opts),
         :ok <- validate_identities(plan["questions"], ids) do
      available_images = MapSet.new(images, & &1.id)

      errors =
        Enum.flat_map(plan["questions"], fn q ->
          CaptainHomework.AI.question_errors(q) ++
            if(ids?(q["image_ids"], available_images),
              do: [],
              else: ["Illustration de question inconnue ou non transmise au modèle."]
            ) ++
            if(
              CaptainHomework.Exams.Constraints.compatible?(
                q["type"],
                q["response_effort"],
                q["answer_basis"],
                pages
              ),
              do: [],
              else: ["Format incompatible avec l'effort ou le mode prévu."]
            )
        end)

      if errors == [], do: :ok, else: {:error, Enum.join(errors, " ")}
    end
  end

  defp validate_identities(_, nil), do: :ok

  defp validate_identities(questions, ids) do
    if Enum.sort(Enum.map(questions, & &1["id"])) == Enum.sort(ids),
      do: :ok,
      else: {:error, "Les identifiants des questions diffèrent de ceux du contrôle."}
  end

  # Collect every independent question diagnostic before making a paid repair call.
  def diagnostics(plan, ids, types, pages, images) do
    questions = Enum.filter(List.wrap(Map.get(plan, "questions")), &is_map/1)
    supports = Enum.filter(List.wrap(Map.get(plan, "supports")), &is_map/1)
    image_ids = MapSet.new(images, & &1.id)

    Enum.reduce(ids, %{}, fn id, errors ->
      matches = Enum.filter(questions, &(&1["id"] == id))

      reasons =
        case matches do
          [q] ->
            own_supports = Enum.filter(supports, &(&1["id"] == q["support_id"]))
            one = %{"questions" => [q], "supports" => own_supports}

            structural =
              case validate(one, 1, types, pages, images) do
                :ok -> []
                {:error, reason} -> [reason]
              end

            content =
              CaptainHomework.AI.question_errors(q) ++
                if(ids?(q["image_ids"], image_ids),
                  do: [],
                  else: ["Illustration de question inconnue ou non transmise au modèle."]
                )

            compatible =
              if CaptainHomework.Exams.Constraints.compatible?(
                   q["type"],
                   q["response_effort"],
                   q["answer_basis"],
                   pages
                 ), do: [], else: ["Format incompatible avec l’effort ou le mode annoncé."]

            duplicates =
              Enum.filter(questions, fn other ->
                same_visual = visual_identity(q) == visual_identity(other)

                known_visuals =
                  ids?(q["image_ids"] || [], image_ids) and
                    ids?(other["image_ids"] || [], image_ids)

                (same_visual or not known_visuals) and other["id"] != id and
                  is_binary(q["objective"]) and is_binary(other["objective"]) and
                  ((normalize(q["objective"]) == normalize(other["objective"]) and
                      q["skill"] == other["skill"]) or
                     (normalized_elements(q) == normalized_elements(other) and
                        q["skill"] == other["skill"]))
              end)

            structural ++
              content ++
              compatible ++
              if(duplicates == [],
                do: [],
                else: ["Notion ou éléments attendus déjà évalués par une autre question."]
              )

          _ ->
            ["Question absente ou identifiant répété."]
        end

      if reasons == [], do: errors, else: Map.put(errors, id, Enum.uniq(reasons))
    end)
  end

  defp normalized_elements(question) do
    question["expected_elements"]
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize/1)
    |> Enum.sort()
  end

  def attach(question, slots, supports) do
    with slot when not is_nil(slot) <- Enum.find(slots, &(&1["id"] == question["plan_id"])),
         true <- question["type"] == slot["type"] do
      question =
        Map.merge(
          question,
          Map.take(slot, [
            "objective",
            "skill",
            "response_effort",
            "answer_basis",
            "expected_elements",
            "source_page_ids",
            "support_id",
            "image_regions"
          ])
        )

      case Enum.find(supports, &(&1["id"] == slot["support_id"])) do
        nil ->
          {:ok, question}

        support ->
          shared_ids = support["image_ids"] || []
          image_ids = Enum.uniq((question["image_ids"] || []) ++ shared_ids)

          # A shared text supplements the question's figures. For shared images,
          # keep the canonical support crop, including an uncropped whole page.
          regions =
            Enum.reject(question["image_regions"] || [], &(&1["image_id"] in shared_ids)) ++
              (support["image_regions"] || [])

          {:ok,
           question
           |> Map.put("support_text", support["text"])
           |> Map.put("image_ids", image_ids)
           |> Map.put("image_regions", regions)
           |> Map.put("support_title", support["title"])}
      end
    else
      _ -> :error
    end
  end

  def sync_review(plan, reviewed) do
    by_id = Map.new(reviewed, &{&1["plan_id"], &1})

    Map.update!(plan, "questions", fn questions ->
      Enum.map(questions, fn question ->
        case by_id[question["id"]] do
          nil ->
            question

          accepted ->
            Map.merge(
              question,
              Map.take(
                accepted,
                ~w(response_effort verified_response_effort verified_answer_basis)
              )
            )
        end
      end)
    end)
  end

  def remaining(plan, kept) do
    ids = MapSet.new(kept, & &1["plan_id"])
    Enum.reject(plan["questions"], &MapSet.member?(ids, &1["id"]))
  end

  def order(questions, nil), do: questions
  def order(questions, %{"rejected_plan" => _}), do: questions
  def order(questions, plan) when not is_map_key(plan, "questions"), do: questions

  def order(questions, plan) do
    positions = plan["questions"] |> Enum.with_index() |> Map.new(fn {q, i} -> {q["id"], i} end)

    support_keys =
      Map.new(plan["supports"], fn support ->
        {support["id"],
         {normalize(support["text"]), Enum.sort(support["image_ids"]),
          Enum.sort(Map.get(support, "image_regions", []))}}
      end)

    keys =
      Map.new(plan["questions"], fn slot ->
        {slot["id"], Map.get(support_keys, slot["support_id"], {:question, slot["id"]})}
      end)

    starts =
      Enum.reduce(plan["questions"], %{}, fn slot, starts ->
        Map.put_new(starts, keys[slot["id"]], positions[slot["id"]])
      end)

    Enum.sort_by(questions, fn question ->
      id = question["plan_id"]
      {Map.get(starts, keys[id], -1), Map.get(positions, id, -1)}
    end)
  end

  def duplicate?(a, b) do
    same_id = is_binary(a["plan_id"]) and a["plan_id"] == b["plan_id"]

    same_objective =
      is_binary(a["objective"]) and is_binary(b["objective"]) and
        normalize(a["objective"]) == normalize(b["objective"]) and a["skill"] == b["skill"]

    same_id or (same_objective and visual_identity(a) == visual_identity(b))
  end

  def visual_identity(question) do
    {Enum.sort(question["image_ids"] || []), Enum.sort(question["image_regions"] || []),
     question["diagram"]}
  end

  defp issue(issues, true, message), do: issues ++ [message]
  defp issue(issues, false, _), do: issues

  defp region_errors(entity) do
    case CaptainHomework.ImageCrops.validate(
           Map.get(entity, "image_ids", []),
           Map.get(entity, "image_regions", [])
         ) do
      :ok -> []
      {:error, message} -> ["Recadrage #{entity["id"]} : #{message}"]
    end
  end

  defp normalize(value),
    do:
      value
      |> String.downcase()
      |> String.normalize(:nfd)
      |> String.replace(~r/\p{Mn}/u, "")
      |> String.replace(~r/[^\p{L}\p{N}]+/u, " ")
      |> String.trim()

  defp unique?(values), do: length(Enum.uniq(values)) == length(values)
  defp text?(value, limit), do: is_binary(value) and byte_size(String.trim(value)) in 1..limit

  defp ids?(values, allowed),
    do:
      is_list(values) and length(values) <= 8 and Enum.all?(values, &MapSet.member?(allowed, &1))
end

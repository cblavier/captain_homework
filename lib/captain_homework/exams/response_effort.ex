defmodule CaptainHomework.Exams.ResponseEffort do
  @categories ~w(direct short developed)

  def review(questions, reviews) when is_list(reviews) do
    ids = Enum.map(questions, & &1["plan_id"])
    reviewed_ids = Enum.map(reviews, & &1["plan_id"])

    if Enum.sort(ids) == Enum.sort(reviewed_ids) and
         length(Enum.uniq(reviewed_ids)) == length(reviewed_ids) and
         Enum.all?(
           reviews,
           &(&1["actual_effort"] in @categories and is_boolean(&1["consistent"]))
         ) do
      by_id = Map.new(reviews, &{&1["plan_id"], &1})

      {accepted, errors} =
        Enum.reduce(questions, {[], []}, fn q, {accepted, errors} ->
          review = Map.fetch!(by_id, q["plan_id"])

          compatible? =
            not Map.has_key?(q, "type") or
              CaptainHomework.Exams.Constraints.effort_supported?(
                q["type"],
                review["actual_effort"]
              )

          if review["consistent"] and compatible? and
               CaptainHomework.Exams.AnswerBasis.review_ok?(q, review) do
            {accepted ++
               [
                 q
                 |> record_effort(review["actual_effort"])
                 |> Map.put("verified_response_effort", review["actual_effort"])
                 |> Map.put("verified_answer_basis", review["actual_basis"])
               ], errors}
          else
            {accepted,
             errors ++
               [
                 "Question #{q["plan_id"]} : effort attendu #{q["response_effort"]}, effort constaté #{review["actual_effort"]}. Mode prévu #{q["answer_basis"]}, mode constaté #{review["actual_basis"]}, réponse exposée #{review["answer_exposed"]}. Corrige uniquement le défaut pédagogique décrit ci-dessous. La catégorie d’effort est descriptive, elle n’impose pas de réécriture à elle seule. Pour knowledge, choisis une notion enseignée dans le cours dont la réponse n'est pas fournie dans les supports du contrôle. Diagnostic : #{review["reason"]}"
               ]}
          end
        end)

      {:ok, accepted, errors}
    else
      {:error, :invalid_effort_review}
    end
  end

  def review(_, _), do: {:error, :invalid_effort_review}

  # Contract metadata is immutable. The review records its classification separately;
  # an incompatible format is rejected above and needs a newly constructed contract.
  defp record_effort(%{"exercise_spec_hash" => hash} = question, _actual)
       when is_binary(hash) and hash != "",
       do: question

  defp record_effort(question, actual), do: Map.put(question, "response_effort", actual)
end

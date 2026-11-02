defmodule CaptainHomework.Exams.ResponseEffort do
  @categories ~w(direct short developed)

  def targets(count, types), do: CaptainHomework.Exams.Constraints.targets(count, types).effort

  def balanced?(questions, types, pages \\ nil) do
    # Legacy plans can still be resumed.
    if Enum.all?(questions, &Map.has_key?(&1, "response_effort")) do
      actual = Enum.frequencies_by(questions, & &1["response_effort"])

      Enum.all?(
        CaptainHomework.Exams.Constraints.targets(length(questions), types, pages).effort,
        fn {key, n} -> Map.get(actual, key, 0) == n end
      )
    else
      true
    end
  end

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

          if review["actual_effort"] == q["response_effort"] and review["consistent"] and
               CaptainHomework.Exams.AnswerBasis.review_ok?(q, review) do
            {accepted ++
               [
                 q
                 |> Map.put("verified_response_effort", review["actual_effort"])
                 |> Map.put("verified_answer_basis", review["actual_basis"])
               ], errors}
          else
            {accepted,
             errors ++
               [
                 "Question #{q["plan_id"]} : effort attendu #{q["response_effort"]}, effort constaté #{review["actual_effort"]}. Mode prévu #{q["answer_basis"]}, mode constaté #{review["actual_basis"]}, réponse exposée #{review["answer_exposed"]}. Réécris la consigne, la réponse et le barème pour respecter l'effort et le mode prévus. Pour knowledge, choisis une notion enseignée dans le cours dont la réponse n'est pas fournie dans les supports du contrôle. Diagnostic : #{review["reason"]}"
               ]}
          end
        end)

      {:ok, accepted, errors}
    else
      {:error, :invalid_effort_review}
    end
  end

  def review(_, _), do: {:error, :invalid_effort_review}
end

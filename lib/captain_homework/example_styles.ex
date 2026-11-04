defmodule CaptainHomework.ExampleStyles do
  require Logger
  alias CaptainHomework.{AI, Repo, Uploads, ProcessingProgress}
  alias CaptainHomework.Study.Page

  @types ~w(definition mcq cloze reading long diagram ordering)
  @choices %{
    "instruction_style" => ~w(concise detailed mixed),
    "grouping" => ~w(by_type by_exercise mixed),
    "response_length" => ~w(short long mixed),
    "numbering" => ~w(numeric alphabetic mixed none)
  }

  def choices, do: @choices
  def types, do: @types

  def schedule(page) do
    if supported?() do
      ProcessingProgress.update(page, 10, "Préparation du profil de forme")
      Logger.info("example_analysis scheduled page_id=#{page.id}")

      case Task.Supervisor.start_child(CaptainHomework.Tasks, fn -> prepare(page) end) do
        {:ok, _pid} -> :ok
        {:error, _reason} -> fail(page, "Impossible de démarrer l’analyse. Réessaie.")
      end
    end

    :ok
  end

  def context(examples) do
    Enum.reduce_while(examples, {:ok, []}, fn page, {:ok, profiles} ->
      case prepare(page) do
        {:ok, profile} -> {:cont, {:ok, profiles ++ [profile]}}
        error -> {:halt, error}
      end
    end)
  end

  def prepare(page) do
    if supported?() do
      :global.trans({{__MODULE__, page.id}, self()}, fn -> prepare_current(page.id) end)
    else
      {:ok, %{}}
    end
  rescue
    error ->
      Logger.error(
        "example_analysis exception page_id=#{page.id} exception=#{inspect(error.__struct__)}"
      )

      fail(page, "L’analyse de la forme a été interrompue. Réessaie.")
  end

  defp prepare_current(id) do
    started = System.monotonic_time(:millisecond)
    Logger.info("example_analysis started page_id=#{id}")
    page = Repo.get!(Page, id)
    data = Uploads.read(page)
    hash = fingerprint(page, data)

    if page.style_hash == hash and is_map(page.style_profile) do
      if page.processing_stage != nil or page.status != "ready" do
        page |> Ecto.Changeset.change(status: "ready", error: nil) |> Repo.update!()
        ProcessingProgress.complete(page)
      end

      Logger.info("example_analysis cached page_id=#{id}")
      {:ok, page.style_profile}
    else
      ProcessingProgress.update(page, 30, "Analyse de la structure et du barème")

      with {:ok, profile} <- AI.provider().analyze_example_style(data, page.content_type),
           :ok <- validate(profile),
           current when not is_nil(current) <- Repo.get(Page, id),
           true <- fingerprint(current, Uploads.read(current)) == hash,
           {:ok, saved} <-
             current
             |> Ecto.Changeset.change(
               style_profile: profile,
               style_hash: hash,
               status: "ready",
               error: nil
             )
             |> Repo.update() do
        ProcessingProgress.complete(saved)

        Logger.info(
          "example_analysis completed page_id=#{id} duration_ms=#{System.monotonic_time(:millisecond) - started}"
        )

        {:ok, profile}
      else
        {:error, reason} -> fail(page, AI.message(reason))
        _ -> fail(page, "Le contrôle d’exemple a changé pendant son analyse. Réessaie.")
      end
    end
  end

  defp fingerprint(page, data) do
    {1, AI.provider(), Application.get_env(:captain_homework, :openai_model), page.content_type,
     :crypto.hash(:sha256, data)}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def validate(profile) when is_map(profile) do
    expected = ["readable", "question_types" | Map.keys(@choices)]

    valid =
      Enum.sort(Map.keys(profile)) == Enum.sort(expected) and profile["readable"] == true and
        Enum.all?(@choices, fn {key, choices} -> profile[key] in choices end) and
        is_list(profile["question_types"]) and length(profile["question_types"]) in 1..6 and
        Enum.all?(profile["question_types"], fn item ->
          is_map(item) and Enum.sort(Map.keys(item)) == ["count", "points", "type"] and
            item["type"] in @types and is_integer(item["count"]) and item["count"] in 1..1000 and
            is_integer(item["points"]) and item["points"] in 0..1000
        end)

    if valid,
      do: :ok,
      else:
        {:error,
         "La structure du contrôle d’exemple est illisible ou invalide. Vérifie la photo puis réessaie."}
  end

  def validate(_), do: {:error, "Le profil de forme reçu est invalide."}

  defp fail(page, reason) do
    import Ecto.Query, only: [from: 2]

    Logger.warning("example_analysis failed page_id=#{page.id}")

    Repo.update_all(from(p in Page, where: p.id == ^page.id),
      set: [status: "error", error: reason]
    )

    ProcessingProgress.clear(page)
    {:error, reason}
  end

  defp supported?,
    do:
      Code.ensure_loaded?(AI.provider()) and
        function_exported?(AI.provider(), :analyze_example_style, 2)
end

defmodule CaptainHomeworkWeb.SharedEvaluationsLive do
  use CaptainHomeworkWeb, :live_view
  import Ecto.Query
  alias CaptainHomework.{Repo, ExamShares, Exams}
  alias CaptainHomework.Study.{Exam, ExamShare}
  alias CaptainHomeworkWeb.{HomeworkLive, ProfilePath}

  def mount(_, session, socket), do: HomeworkLive.mount(%{}, session, socket)

  def handle_params(params, _, socket) do
    profile = ProfilePath.find(params["child"])
    if is_nil(profile), do: raise(Ecto.NoResultsError, queryable: Exam)

    shares =
      Repo.all(
        from s in ExamShare,
          join: e in assoc(s, :exam),
          join: l in assoc(e, :lesson),
          where: l.profile_id == ^profile.id and is_nil(s.revoked_at),
          order_by: [desc: s.inserted_at, desc: s.id],
          preload: [exam: {e, lesson: l}]
      )

    rows =
      Enum.map(shares, fn share ->
        %{
          id: share.id,
          share: share,
          attempts:
            Enum.sort_by(
              ExamShares.attempts_for_exam(share.exam_id)
              |> Enum.filter(&(&1.exam_share_id == share.id)),
              & &1.inserted_at,
              {:desc, DateTime}
            )
        }
      end)

    socket =
      assign(socket, profile: profile, page_title: "Évaluations partagées", empty?: rows == [])

    if socket.assigns.live_action == :exam do
      ids =
        Enum.flat_map(rows, fn row -> [row.share.exam_id | Enum.map(row.attempts, & &1.id)] end)

      unless params["id"] in ids, do: raise(Ecto.NoResultsError, queryable: Exam)
      exam = Repo.get!(Exam, params["id"]) |> Repo.preload(:lesson)
      unless exam.status == "completed", do: raise(Ecto.NoResultsError, queryable: Exam)
      {:noreply, HomeworkLive.load_shared_exam(socket, exam, profile)}
    else
      {:noreply, stream(socket, :shares, rows, reset: true)}
    end
  end

  def render(%{live_action: :exam} = assigns), do: HomeworkLive.render(assigns)

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} child_theme={@profile.theme}>
      <main id="shared-evaluations-page" class="app">
        <.profile_header profile={@profile} profiles={@profiles} form={@form} />
        <section class="shared-evaluations-section">
          <div class="page-heading">
            <.page_breadcrumb
              id="shared-evaluations-title"
              ancestors={[
                {:home, ProfilePath.child_path(@profile, "/")},
                {"Paramètres", ProfilePath.child_path(@profile, "/parametres")}
              ]}
            >
              Évaluations partagées
            </.page_breadcrumb>
          </div>
          <div :if={@empty?} id="shared-evaluations-empty" class="empty-state">
            <.icon name="book" />
            <h2>Aucune évaluation partagée</h2>
            <p>Les contrôles que tu partages apparaîtront ici.</p>
          </div>
          <div id="shared-evaluations" class="shared-evaluations-list" phx-update="stream">
            <article
              :for={{id, row} <- @streams.shares}
              id={id}
              class="settings-card shared-evaluation"
            >
              <header class="shared-evaluation-heading">
                <div class="shared-evaluation-copy">
                  <p class="eyebrow">
                    {if row.share.mode == "fill", do: "À remplir", else: "Correction"}
                  </p>
                  <h2>{row.share.exam.lesson.title}</h2>
                </div>
                <div class="shared-evaluation-actions">
                  <span class="status-badge">
                    {if expired?(row.share), do: "Expiré", else: "Actif"}
                  </span>
                  <button
                    id={"delete-share-#{row.id}"}
                    type="button"
                    class="icon-button"
                    phx-click="delete_share"
                    phx-value-id={row.id}
                    aria-label={"Supprimer le lien de partage de « #{row.share.exam.lesson.title} »"}
                    title="Supprimer le lien de partage"
                    data-confirm="Supprimer ce lien de partage ? Il ne fonctionnera plus. L’évaluation d’origine et les copies enregistrées seront conservées."
                  >
                    <.icon name="trash" />
                  </button>
                </div>
              </header>
              <dl class="shared-evaluation-dates">
                <div>
                  <dt>Partagé le</dt>
                  <dd>{date(row.share.inserted_at)}</dd>
                </div>
                <div>
                  <dt>Expiration</dt>
                  <dd>{date(row.share.expires_at)}</dd>
                </div>
              </dl>
              <.link
                :if={row.share.mode == "correction"}
                class="button secondary"
                navigate={correction_path(@profile, row.share.exam_id)}
              >
                Ouvrir la correction <.icon name="arrow" />
              </.link>
              <p
                :if={row.share.mode == "fill" && row.attempts == []}
                class="muted shared-evaluation-empty"
              >
                Aucune copie commencée.
              </p>
              <ul :if={row.attempts != []} class="shared-evaluation-attempts" aria-label="Copies">
                <li :for={{exam, index} <- Enum.with_index(row.attempts, 1)}>
                  <% state = attempt_status(exam) %>
                  <div class="shared-attempt-label">
                    <span>Copie {index}</span>
                    <span
                      id={"shared-attempt-status-#{exam.id}"}
                      class={["status-badge", "shared-attempt-status"]}
                      data-status={state}
                    >
                      {status(state)}
                    </span>
                  </div>
                  <.link
                    :if={exam.status == "completed"}
                    class="button secondary"
                    navigate={correction_path(@profile, exam.id)}
                    aria-label={"Ouvrir la correction de la copie #{index}"}
                  >
                    Ouvrir la correction <.icon name="arrow" />
                  </.link>
                </li>
              </ul>
            </article>
          </div>
        </section>
      </main>
    </Layouts.app>
    """
  end

  def handle_event("delete_share", %{"id" => id}, socket) do
    case ExamShares.revoke(socket.assigns.profile.id, id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Lien de partage supprimé.")
         |> push_navigate(
           to: ProfilePath.child_path(socket.assigns.profile, "/parametres/partages")
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Le lien de partage n’a pas pu être supprimé.")}
    end
  end

  def handle_event(event, params, socket) when event in ["close_modal", "explain_language"],
    do: HomeworkLive.handle_event(event, params, socket)

  def handle_event(_, _, socket), do: {:noreply, socket}
  def handle_info(_, socket), do: {:noreply, socket}

  defp correction_path(profile, id),
    do: ProfilePath.child_path(profile, "/parametres/partages/#{id}")

  defp expired?(share),
    do: share.expires_at && DateTime.compare(share.expires_at, DateTime.utc_now()) != :gt

  defp date(nil), do: "Sans expiration"
  defp date(value), do: Calendar.strftime(value, "%d/%m/%Y à %H:%M UTC")

  defp attempt_status(%{status: "in_progress"} = exam) do
    if Enum.any?(exam.questions, &(not Exams.blank?((exam.answers || %{})[&1["id"]]))),
      do: "in_progress",
      else: "not_started"
  end

  defp attempt_status(exam), do: exam.status

  defp status("not_started"), do: "Non commencée"
  defp status("completed"), do: "Corrigée"
  defp status("grading"), do: "Correction en cours"
  defp status("in_progress"), do: "En cours"
  defp status(_), do: "En erreur"
end

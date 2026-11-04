defmodule CaptainHomeworkWeb.SharedExamLive do
  use CaptainHomeworkWeb, :live_view
  alias CaptainHomework.{ExamShares, Exams, Repo, Study}
  alias CaptainHomeworkWeb.HomeworkLive

  @read_events ~w(close_modal explain_language)
  @answer_events ~w(save_answers order_answer validate_card next_card confirm_submit cancel_submit submit_exam remove_drawing_photo open_ocr transcribe_answer use_transcription cancel_upload)

  @impl true
  def mount(%{"token" => token}, session, socket) do
    with {:ok, share, exam} <- ExamShares.open(token, session["shared_visitor"]) do
      owner =
        Study.get_profile(exam.lesson.profile_id) || Repo.preload(exam.lesson, :profile).profile

      profile = %{
        id: {:shared, token, session["shared_visitor"]},
        name: if(share.mode == "correction", do: owner.name, else: "l’élève"),
        theme: owner.theme,
        share_token: token
      }

      Exams.recover_stale(exam)
      exam = Study.get_exam!(profile.id, exam.id)
      {:ok, socket} = HomeworkLive.mount(%{}, %{"shared" => true}, socket)

      if connected?(socket) and share.expires_at do
        delay = max(1, DateTime.diff(share.expires_at, DateTime.utc_now(), :millisecond))
        Process.send_after(self(), :share_expired, delay)
      end

      {:ok,
       socket
       |> assign(share_mode: share.mode, share_available: true)
       |> HomeworkLive.load_shared_exam(exam, profile)}
    else
      _ -> {:ok, assign(socket, share_available: false, page_title: "Lien indisponible")}
    end
  end

  @impl true
  def render(%{share_available: true} = assigns), do: HomeworkLive.render(assigns)

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <main class="app shared-exam" id="share-unavailable">
        <section class="panel">
          <h1>Ce lien n’est plus disponible</h1>
          <p>Le lien a expiré ou le contrôle a été supprimé.</p>
        </section>
      </main>
    </Layouts.app>
    """
  end

  @impl true
  def handle_event(event, params, %{assigns: %{share_available: true}} = socket) do
    cond do
      not available?(socket) ->
        {:noreply, expire(socket)}

      event in @read_events ->
        HomeworkLive.handle_event(event, params, socket)

      event in @answer_events and socket.assigns.share_mode == "fill" ->
        HomeworkLive.handle_event(event, params, socket)

      true ->
        {:noreply, socket}
    end
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  @impl true
  def handle_info(:share_expired, socket), do: {:noreply, expire(socket)}

  def handle_info(message, %{assigns: %{share_available: true}} = socket)
      when message in [:exam_updated, :refresh_exam] do
    if available?(socket),
      do: HomeworkLive.handle_info(message, socket),
      else: {:noreply, expire(socket)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  @impl true
  def handle_async(name, result, socket) do
    if socket.assigns.share_available and available?(socket),
      do: HomeworkLive.handle_async(name, result, socket),
      else: {:noreply, expire(socket)}
  end

  defp available?(socket),
    do: match?({:ok, _}, ExamShares.fetch(socket.assigns.profile.share_token))

  defp expire(socket) do
    if socket.assigns[:exam_refresh_timer],
      do: Process.cancel_timer(socket.assigns.exam_refresh_timer)

    assign(socket, share_available: false, page_title: "Lien indisponible")
  end
end

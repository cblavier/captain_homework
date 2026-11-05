defmodule CaptainHomeworkWeb.GenerationNotifications do
  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]
  alias CaptainHomework.{Repo, Study}
  alias CaptainHomeworkWeb.ProfilePath

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(CaptainHomework.PubSub, "exam_generation")

    {:cont,
     socket
     |> assign(:generation_notifications_seen, MapSet.new())
     |> attach_hook(:generation_notifications, :handle_info, &handle_notification/2)}
  end

  defp handle_notification({:exam_generation_finished, exam}, socket) do
    key = {exam.id, exam.generation_started_at}
    seen = socket.assigns.generation_notifications_seen

    viewing_exam? =
      socket.view == CaptainHomeworkWeb.HomeworkLive and socket.assigns.live_action == :exam and
        match?(%{id: id} when id == exam.id, socket.assigns[:exam])

    socket =
      if MapSet.member?(seen, key) or viewing_exam? do
        socket
      else
        put_notification(socket, exam)
      end

    {:halt, assign(socket, :generation_notifications_seen, MapSet.put(seen, key))}
  end

  defp handle_notification(_message, socket), do: {:cont, socket}

  defp put_notification(socket, exam) do
    with %Study.Lesson{} = lesson <- Repo.get(Study.Lesson, exam.lesson_id),
         %Study.Profile{} = profile <- Repo.get(Study.Profile, lesson.profile_id),
         true <- CaptainHomework.Accounts.profile_allowed?(socket.assigns.account, profile) do
      success? = exam.status == "in_progress"

      put_flash(socket, if(success?, do: :info, else: :error), %{
        "title" => if(success?, do: "Contrôle prêt", else: "Création du contrôle échouée"),
        "message" => "#{profile.name} · #{lesson.title}",
        "href" => ProfilePath.child_path(profile, "/controles/#{exam.id}")
      })
    else
      _ -> socket
    end
  end
end

defmodule CaptainHomeworkWeb.HomeworkLive do
  use CaptainHomeworkWeb, :live_view
  alias CaptainHomework.{Study, Exams, AI, Uploads, Repo, Resources}
  alias CaptainHomework.Study.Page
  import Ecto.Query
  alias CaptainHomeworkWeb.ProfilePath
  import CaptainHomeworkWeb.ProfilePath, only: [child_path: 2]

  @impl true
  def mount(_params, session, socket) do
    profiles = Study.profiles()
    profile = Enum.find(profiles, &(&1.id == session["profile_id"])) || List.first(profiles)

    socket =
      assign(socket,
        form: to_form(%{}),
        resource_form: to_form(%{"url" => ""}, as: :resource),
        settings_form: nil,
        subjects_form: nil,
        profiles: profiles,
        profile: profile,
        subjects: Study.subjects(),
        counts: %{},
        subject: nil,
        lesson: nil,
        lesson_tab: "controles",
        exam: nil,
        lessons_empty?: true,
        modal: nil,
        page_title: "Mes matières",
        error: nil,
        busy: false,
        busy_text: nil,
        question_count: 10,
        instructions: "",
        example_ids: [],
        answers: %{},
        edit_page: nil,
        page_text: "",
        ocr_text: nil,
        ocr_question: nil,
        page_dirty: false,
        saved: nil,
        subscribed_lesson: nil,
        subscribed_exam: nil,
        confirming: false
      )

    {:ok,
     socket
     |> stream(:lessons, [])
     |> stream_configure(:resources, dom_id: &"resource-#{&1.id}")
     |> stream(:resources, [])
     |> allow_upload(:pages,
       accept: ~w(.jpg .jpeg .png .webp),
       max_entries: 20,
       max_file_size: 12_000_000
     )
     |> allow_upload(:examples,
       accept: ~w(.jpg .jpeg .png .webp),
       max_entries: 5,
       max_file_size: 12_000_000
     )
     |> allow_upload(:resources,
       accept: ~w(.pdf .jpg .jpeg .png .webp),
       max_entries: 5,
       max_file_size: 20_000_000
     )
     |> allow_upload(:answer_photo,
       accept: ~w(.jpg .jpeg .png .webp),
       max_entries: 1,
       max_file_size: 12_000_000
     )}
  end

  @impl true
  def handle_params(params, url, socket) do
    profile =
      if params["child"] do
        Enum.find(Study.profiles(), &ProfilePath.matches?(&1, params["child"])) ||
          raise Ecto.NoResultsError, queryable: CaptainHomework.Study.Profile
      else
        if socket.assigns.profile, do: Study.get_profile(socket.assigns.profile.id)
      end

    socket = assign(socket, profile: profile)
    socket = assign(socket, modal: nil, error: nil, busy: false, confirming: false)

    current_path = URI.parse(url).path

    cond do
      profile && params["child"] &&
          (String.starts_with?(current_path, "/enfants/") ||
             params["child"] != ProfilePath.slug(profile)) ->
        suffix = Regex.replace(~r{^/(?:enfants/)?[^/]+}, current_path, "")

        {:noreply,
         push_navigate(socket, to: child_path(profile, if(suffix == "", do: "/", else: suffix)))}

      profile && !params["child"] ->
        {:noreply, push_navigate(socket, to: child_path(profile, URI.parse(url).path))}

      profile == nil and socket.assigns.live_action != :settings ->
        {:noreply, assign(socket, page_title: "Mon espace")}

      true ->
        socket = load_page(socket, params)
        title = socket.assigns.page_title
        title = if profile, do: "#{profile.name} - #{title}", else: title
        {:noreply, assign(socket, page_title: title)}
    end
  end

  defp subject_preferences_form(nil), do: nil

  defp subject_preferences_form(profile) do
    to_form(%{"enabled_ids" => Enum.map(Study.enabled_subjects(profile), & &1.id)}, as: :subjects)
  end

  defp load_page(socket, params) do
    profile = socket.assigns.profile

    case socket.assigns.live_action do
      :settings ->
        assign(socket,
          page_title: "Paramètres",
          settings_form: to_form(CaptainHomework.Settings.change(), as: :settings),
          subjects_form: subject_preferences_form(profile)
        )

      :home ->
        assign(socket,
          page_title: "Mes matières",
          counts: Study.counts(profile.id),
          subjects: Study.enabled_subjects(profile)
        )

      :subject ->
        subject = Study.subject!(params["subject"])

        lessons = Study.lessons(profile.id, subject.id)

        socket
        |> assign(subject: subject, page_title: subject.name, lessons_empty?: lessons == [])
        |> stream(:lessons, lessons, reset: true)

      action when action in [:lesson, :new_exam] ->
        lesson = Study.get_lesson!(profile.id, params["id"])
        socket = subscribe(socket, :lesson, lesson.id)

        assign(socket,
          lesson: lesson,
          lesson_tab:
            if(params["onglet"] in ["cours", "ressources"],
              do: params["onglet"],
              else: "controles"
            ),
          subject: Study.subject!(lesson.subject),
          page_title:
            if(action == :new_exam,
              do: "Nouveau contrôle",
              else:
                Map.get(
                  %{"cours" => "Cours", "ressources" => "Ressources"},
                  params["onglet"],
                  "Contrôles"
                )
            ),
          instructions: "",
          question_count: 10,
          example_ids: []
        )
        |> stream(:resources, lesson.resources, reset: true)

      :exam ->
        exam = Study.get_exam!(profile.id, params["id"])
        Exams.recover_stale(exam)
        exam = Study.get_exam!(profile.id, params["id"])
        socket = subscribe(socket, :exam, exam.id)

        if connected?(socket) and exam.status in ["grading", "generating"],
          do: Process.send_after(self(), :refresh_exam, 2000)

        assign(socket,
          exam: exam,
          lesson: exam.lesson,
          subject: Study.subject!(exam.lesson.subject),
          answers: exam.answers,
          error: exam.error,
          page_title: "Contrôle"
        )
    end
  end

  defp subscribe(socket, kind, id) do
    key = if kind == :lesson, do: :subscribed_lesson, else: :subscribed_exam
    old = socket.assigns[key]

    if connected?(socket) and old != id do
      if old, do: Phoenix.PubSub.unsubscribe(CaptainHomework.PubSub, "#{kind}:#{old}")
      Phoenix.PubSub.subscribe(CaptainHomework.PubSub, "#{kind}:#{id}")
    end

    assign(socket, key, id)
  end

  @impl true
  def handle_event("open_modal", %{"modal" => modal}, socket),
    do: {:noreply, assign(socket, modal: modal, error: nil)}

  def handle_event("close_modal", _, socket),
    do: {:noreply, assign(socket, modal: nil, error: nil, ocr_text: nil)}

  def handle_event("validate", _, socket), do: {:noreply, socket}

  def handle_event("cancel_upload", %{"name" => name, "ref" => ref}, socket) do
    upload =
      case name do
        "pages" -> :pages
        "examples" -> :examples
        "resources" -> :resources
        "answer_photo" -> :answer_photo
      end

    {:noreply, cancel_upload(socket, upload, ref)}
  end

  def handle_event("create_lesson", %{"title" => title}, socket) do
    attrs = %{"title" => String.trim(title), "subject" => socket.assigns.subject.id}

    case Study.create_lesson(socket.assigns.profile, attrs) do
      {:ok, lesson} ->
        {socket, _} = save_uploads(socket, :pages, lesson, "lesson")

        {:noreply,
         push_navigate(socket, to: child_path(socket.assigns.profile, ~p"/lecons/#{lesson.id}"))}

      _ ->
        {:noreply, assign(socket, error: "Donne un nom à la leçon (120 caractères maximum).")}
    end
  end

  def handle_event("upload_pages", _, socket) do
    {socket, _} = save_uploads(socket, :pages, socket.assigns.lesson, "lesson")
    {:noreply, socket |> assign(modal: nil) |> refresh_lesson()}
  end

  def handle_event("upload_examples", _, socket) do
    {socket, _} = save_uploads(socket, :examples, socket.assigns.lesson, "example")
    {:noreply, refresh_lesson(socket)}
  end

  def handle_event("upload_resources", _, socket) do
    results =
      consume_uploaded_entries(socket, :resources, fn %{path: path}, entry ->
        {:ok,
         Resources.create_upload(
           socket.assigns.profile.id,
           socket.assigns.lesson.id,
           path,
           entry.client_name
         )}
      end)

    socket =
      Enum.reduce(results, socket, fn
        {:ok, resource}, socket ->
          launch_resource(resource)
          socket

        {:error, reason}, socket ->
          put_flash(socket, :error, AI.message(reason))
      end)

    {:noreply, refresh_lesson(socket)}
  end

  def handle_event("add_resource_url", %{"resource" => %{"url" => url}}, socket) do
    case Resources.create_url(
           socket.assigns.profile.id,
           socket.assigns.lesson.id,
           String.trim(url)
         ) do
      {:ok, resource} ->
        launch_resource(resource)

        {:noreply,
         socket
         |> assign(resource_form: to_form(%{"url" => ""}, as: :resource))
         |> refresh_lesson()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, AI.message(reason))}
    end
  end

  def handle_event("retry_resource", %{"id" => id}, socket) do
    case Resources.retry(socket.assigns.profile.id, id) do
      {:ok, resource} ->
        launch_resource(resource)
        {:noreply, refresh_lesson(socket)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, AI.message(reason))}
    end
  end

  def handle_event("delete_resource", %{"id" => id}, socket) do
    case Resources.delete(socket.assigns.profile.id, id) do
      {:ok, _} -> {:noreply, refresh_lesson(socket)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, AI.message(reason))}
    end
  end

  def handle_event("edit_page", %{"id" => id}, socket) do
    page = Study.get_page!(socket.assigns.profile.id, id)

    {:noreply,
     assign(socket,
       edit_page: page,
       page_text: page.text,
       modal: "edit_page",
       error: nil,
       page_dirty: false
     )}
  end

  def handle_event("validate_page", %{"text" => text}, socket),
    do: {:noreply, assign(socket, page_text: text, page_dirty: true)}

  def handle_event("save_page", %{"text" => text}, socket) do
    page = Study.get_page!(socket.assigns.profile.id, socket.assigns.edit_page.id)

    case Study.update_page(page, text) do
      {:ok, _} ->
        {:noreply, socket |> assign(modal: nil) |> refresh_lesson()}

      _ ->
        {:noreply, assign(socket, error: "Le texte est trop long (60 000 caractères maximum).")}
    end
  end

  def handle_event("delete_lesson", _, socket) do
    {:ok, lesson} = Study.delete_lesson(socket.assigns.profile.id, socket.assigns.lesson.id)

    {:noreply,
     push_navigate(socket,
       to: child_path(socket.assigns.profile, ~p"/matieres/#{lesson.subject}")
     )}
  end

  def handle_event("delete_exam", _, socket) do
    case Study.delete_exam(socket.assigns.profile.id, socket.assigns.exam.id) do
      {:ok, exam} ->
        {:noreply,
         push_navigate(socket,
           to: child_path(socket.assigns.profile, ~p"/lecons/#{exam.lesson_id}")
         )}

      {:error, :already_submitted} ->
        {:noreply, put_flash(socket, :error, "Un contrôle rendu ne peut pas être supprimé.")}
    end
  end

  def handle_event("move_page", %{"id" => id, "direction" => direction}, socket)
      when direction in ["previous", "next"] do
    case Study.move_page(socket.assigns.profile.id, socket.assigns.lesson.id, id, direction) do
      {:ok, _} ->
        {:noreply, refresh_lesson(socket)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Cette page n’est plus disponible.")}
    end
  end

  def handle_event("delete_page", %{"id" => id}, socket) do
    page = Study.get_page!(socket.assigns.profile.id, id)
    Study.delete_page(page)
    {:noreply, refresh_lesson(socket)}
  end

  def handle_event("transcribe_page", %{"id" => id}, socket) do
    page = Study.get_page!(socket.assigns.profile.id, id)
    launch_ocr(page)

    {:noreply,
     socket
     |> assign(edit_page: %{page | status: "pending", error: nil}, page_dirty: false)
     |> refresh_lesson()}
  end

  def handle_event("save_subjects", %{"subjects" => params}, socket) do
    enabled_ids = params["enabled_ids"] || []

    enabled_ids =
      if is_list(enabled_ids), do: Enum.reject(enabled_ids, &(&1 == "")), else: enabled_ids

    case socket.assigns.profile && Study.save_subjects(socket.assigns.profile, enabled_ids) do
      {:ok, profile} ->
        {:noreply,
         socket
         |> assign(profile: profile, subjects_form: subject_preferences_form(profile))
         |> put_flash(:info, "Matières enregistrées pour #{profile.name}.")}

      _ ->
        {:noreply, put_flash(socket, :error, "Impossible d’enregistrer les matières.")}
    end
  end

  def handle_event("save_settings", %{"settings" => params}, socket) do
    case CaptainHomework.Settings.save(params) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(settings_form: to_form(CaptainHomework.Settings.change(), as: :settings))
         |> put_flash(:info, "Instructions par défaut enregistrées.")}

      {:error, changeset} ->
        {:noreply, assign(socket, settings_form: to_form(changeset, as: :settings))}
    end
  end

  def handle_event("configure_exam", params, socket) do
    {:noreply,
     assign(socket,
       instructions: params["instructions"] || socket.assigns.instructions,
       example_ids: params["example_ids"] || []
     )}
  end

  def handle_event("change_count", %{"delta" => delta}, socket) do
    value = socket.assigns.question_count + String.to_integer(delta)
    {:noreply, assign(socket, question_count: value |> max(1) |> min(30))}
  end

  def handle_event(event, _, %{assigns: %{busy: true}} = socket)
      when event in ["generate_exam", "resume_generation"], do: {:noreply, socket}

  def handle_event("generate_exam", params, socket) do
    parent = self()
    profile_id = socket.assigns.profile.id
    lesson_id = socket.assigns.lesson.id
    count = socket.assigns.question_count
    instructions = params["instructions"] || socket.assigns.instructions
    examples = Enum.uniq(params["example_ids"] || [])

    socket =
      socket
      |> assign(busy: true, busy_text: "Préparation du contrôle…", error: nil)
      |> start_async(:generate, fn ->
        Exams.generate(profile_id, lesson_id, count, instructions, examples,
          progress: fn message -> send(parent, {:generation_progress, message}) end
        )
      end)

    {:noreply, socket}
  end

  def handle_event("resume_generation", _, socket) do
    parent = self()
    profile_id = socket.assigns.profile.id
    exam_id = socket.assigns.exam.id

    {:noreply,
     socket
     |> assign(busy: true, busy_text: "Reprise des questions manquantes…", error: nil)
     |> start_async(:generate, fn ->
       Exams.resume_generation(profile_id, exam_id,
         progress: fn message -> send(parent, {:generation_progress, message}) end
       )
     end)}
  end

  def handle_event("save_answers", %{"answers" => answers}, socket) do
    case Study.save_answers(socket.assigns.profile.id, socket.assigns.exam.id, answers) do
      {:ok, exam} ->
        {:noreply,
         assign(socket,
           exam: exam,
           answers: exam.answers,
           saved: System.system_time(:millisecond)
         )}

      _ ->
        {:noreply, refresh_exam(socket)}
    end
  end

  def handle_event("save_answers", _, socket), do: {:noreply, socket}

  def handle_event("confirm_submit", params, socket) do
    answers = params["answers"] || socket.assigns.answers
    Study.save_answers(socket.assigns.profile.id, socket.assigns.exam.id, answers)
    {:noreply, assign(socket, answers: answers, confirming: true)}
  end

  def handle_event("cancel_submit", _, socket), do: {:noreply, assign(socket, confirming: false)}

  def handle_event("submit_exam", _, socket) do
    case Exams.submit(socket.assigns.profile.id, socket.assigns.exam.id, socket.assigns.answers) do
      {:ok, _} ->
        Process.send_after(self(), :refresh_exam, 2000)
        {:noreply, socket |> assign(confirming: false, error: nil) |> refresh_exam()}

      _ ->
        {:noreply, refresh_exam(socket)}
    end
  end

  def handle_event("open_ocr", %{"id" => id}, socket) do
    q = Enum.find(socket.assigns.exam.questions, &(&1["id"] == id))

    if q && q["type"] in ~w(long reading definition) &&
         socket.assigns.exam.status == "in_progress" do
      {:noreply,
       assign(socket, modal: "answer_photo", ocr_question: id, ocr_text: nil, error: nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("transcribe_answer", _, socket) do
    results =
      consume_uploaded_entries(socket, :answer_photo, fn %{path: path}, _ ->
        data = File.read!(path)

        {:ok,
         case Uploads.image_type(data) do
           {:ok, type, _} -> {data, type}
           _ -> :invalid
         end}
      end)

    case results do
      [{data, type}] ->
        {:noreply,
         socket
         |> assign(busy: true, busy_text: "Lecture de ta réponse…")
         |> start_async(:ocr_answer, fn -> AI.transcribe(data, type) end)}

      _ ->
        {:noreply, assign(socket, error: "Choisis une photo JPEG, PNG ou WebP.")}
    end
  end

  def handle_event("use_transcription", %{"text" => text}, socket) do
    answers = Map.put(socket.assigns.answers, socket.assigns.ocr_question, text)

    case Study.save_answers(socket.assigns.profile.id, socket.assigns.exam.id, answers) do
      {:ok, exam} ->
        {:noreply, assign(socket, answers: exam.answers, exam: exam, modal: nil, ocr_text: nil)}

      _ ->
        {:noreply, refresh_exam(socket)}
    end
  end

  @impl true
  def handle_async(:generate, {:ok, {:ok, exam}}, socket),
    do:
      {:noreply,
       socket
       |> assign(busy: false)
       |> push_navigate(to: child_path(socket.assigns.profile, ~p"/controles/#{exam.id}"))}

  def handle_async(:ocr_answer, {:ok, {:ok, text}}, socket),
    do: {:noreply, assign(socket, busy: false, ocr_text: text)}

  def handle_async(_, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, busy: false, error: AI.message(reason))}

  def handle_async(_, {:exit, _}, socket),
    do: {:noreply, assign(socket, busy: false, error: "L’opération a été interrompue. Réessaie.")}

  @impl true
  def handle_info({:generation_progress, message}, socket) do
    {:noreply, assign(socket, busy_text: message)}
  end

  def handle_info(:lesson_updated, socket) do
    socket = refresh_lesson(socket)

    socket =
      if socket.assigns.modal == "edit_page" do
        page = Study.get_page!(socket.assigns.profile.id, socket.assigns.edit_page.id)

        socket
        |> assign(edit_page: page)
        |> assign(
          :page_text,
          if(socket.assigns.page_dirty, do: socket.assigns.page_text, else: page.text)
        )
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_info(message, socket) when message in [:exam_updated, :refresh_exam] do
    if socket.assigns.live_action == :exam do
      socket = refresh_exam(socket)

      if socket.assigns.exam.status in ["grading", "generating"],
        do: Process.send_after(self(), :refresh_exam, 2000)

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  defp refresh_lesson(socket) do
    lesson = Study.get_lesson!(socket.assigns.profile.id, socket.assigns.lesson.id)
    socket |> assign(lesson: lesson) |> stream(:resources, lesson.resources, reset: true)
  end

  defp refresh_exam(socket) do
    exam = Study.get_exam!(socket.assigns.profile.id, socket.assigns.exam.id)
    Exams.recover_stale(exam)
    exam = Study.get_exam!(socket.assigns.profile.id, exam.id)
    assign(socket, exam: exam, answers: exam.answers, error: exam.error)
  end

  defp save_uploads(socket, name, lesson, kind) do
    results =
      consume_uploaded_entries(socket, name, fn %{path: path}, entry ->
        {:ok, Uploads.store(path, entry.client_name)}
      end)

    Enum.reduce(results, {socket, []}, fn
      {:ok, attrs}, {s, ids} ->
        case Study.add_page(lesson, Map.put(attrs, :kind, kind)) do
          {:ok, page} ->
            if kind == "lesson", do: launch_ocr(page)
            {s, ids ++ [page.id]}

          _ ->
            File.rm(Uploads.path(attrs.storage_key))
            {assign(s, error: "La page n’a pas pu être enregistrée."), ids}
        end

      {:error, reason}, {s, ids} ->
        {assign(s, error: reason), ids}
    end)
  end

  defp launch_resource(resource) do
    Task.Supervisor.start_child(CaptainHomework.Tasks, fn -> Resources.process(resource.id) end)
  end

  defp resource_status(resource) do
    case resource.status do
      "ready" -> "Prête pour les contrôles"
      "error" -> "Import à reprendre"
      _ -> "Import et lecture en cours…"
    end
  end

  defp resource_pages(lesson, resource_id),
    do: Enum.filter(lesson.pages, &(&1.resource_id == resource_id and &1.kind == "resource"))

  defp resource_images(lesson, resource_id),
    do: Enum.filter(lesson.pages, &(&1.resource_id == resource_id and &1.kind == "illustration"))

  defp resource_priority?(lesson, resource_id),
    do:
      Enum.any?(
        resource_pages(lesson, resource_id),
        &(&1.document_kind in ["assessment", "activity"])
      )

  defp launch_ocr(page) do
    work = fn ->
      result =
        try do
          AI.transcribe(Uploads.read(page), page.content_type)
        rescue
          _ -> {:error, "Lecture interrompue. Réessaie."}
        end

      attrs =
        case result do
          {:ok, text} -> %{text: text, status: "ready", error: nil}
          {:error, reason} -> %{status: "error", error: AI.message(reason)}
        end

      # Never overwrite text that was manually saved while OCR was running.
      Repo.update_all(from(p in Page, where: p.id == ^page.id and p.status == "pending"),
        set: Map.to_list(attrs)
      )

      Phoenix.PubSub.broadcast(
        CaptainHomework.PubSub,
        "lesson:#{page.lesson_id}",
        :lesson_updated
      )
    end

    if AI.configured?() do
      page |> Page.changeset(%{status: "pending", error: nil}) |> Repo.update()
      Task.Supervisor.start_child(CaptainHomework.Tasks, work)
    else
      work.()
    end
  end

  defp date(nil), do: ""
  defp date(%Date{} = date), do: Calendar.strftime(date, "%d/%m/%Y")
  defp date(date), do: Calendar.strftime(date, "%d/%m/%Y")

  defp number(n) when is_number(n),
    do:
      :erlang.float_to_binary(n * 1.0, decimals: 2)
      |> String.trim_trailing("0")
      |> String.trim_trailing(".")
      |> String.replace(".", ",")

  defp type_name(type),
    do:
      %{
        "definition" => "Définition",
        "mcq" => "QCM",
        "cloze" => "Texte à trous",
        "reading" => "Compréhension",
        "long" => "Réponse rédigée",
        "diagram" => "Schéma"
      }[type]

  defp readable_text(text), do: Regex.replace(~r/\{\{([^}]+)\}\}/, text, "_____ (\\1) _____")

  defp page_status(page) do
    case page.status do
      "pending" -> "Lecture en cours…"
      "error" -> "Texte à vérifier"
      _ -> "Texte reconnu"
    end
  end

  defp slots_value(answers, id, slot),
    do: if(is_map(answers[id]), do: answers[id][slot] || "", else: "")

  defp answer_text(answer) when is_map(answer),
    do: answer |> Enum.sort() |> Enum.map_join(" · ", fn {k, v} -> "#{k} : #{v}" end)

  defp answer_text(answer), do: if(Exams.blank?(answer), do: "Sans réponse", else: answer)

  defp completed_count(exam, answers),
    do: Enum.count(exam.questions, &(not Exams.blank?(answers[&1["id"]])))

  defp upload_error(:too_large), do: "Image trop volumineuse (12 Mo maximum)."
  defp upload_error(:too_many_files), do: "Trop de fichiers sélectionnés."
  defp upload_error(:not_accepted), do: "Format accepté : JPEG, PNG ou WebP."
  defp upload_error(_), do: "Le transfert a échoué. Réessaie."
  attr :upload, :any, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true

  defp upload_field(assigns) do
    ~H"""
    <div class="upload-area" phx-drop-target={@upload.ref}>
      <label class="upload-label" for={@upload.ref}>
        <.icon name="upload" /><span>{@label}</span> <.live_file_input upload={@upload} />
      </label>
      <div :for={entry <- @upload.entries} class="upload-entry">
        <.live_img_preview :if={String.starts_with?(entry.client_type, "image/")} entry={entry} />
        <.icon :if={!String.starts_with?(entry.client_type, "image/")} name="paper" />
        <span>
          {entry.client_name}
        </span>
        <progress max="100" value={entry.progress} />
        <button
          type="button"
          class="icon-button"
          phx-click="cancel_upload"
          phx-value-name={@name}
          phx-value-ref={entry.ref}
          aria-label="Retirer le fichier"
        >
          <.icon name="close" />
        </button>
        <p :for={error <- upload_errors(@upload, entry)} class="error">{upload_error(error)}</p>
      </div>
      <p :for={error <- upload_errors(@upload)} class="error">{upload_error(error)}</p>
    </div>
    """
  end
end

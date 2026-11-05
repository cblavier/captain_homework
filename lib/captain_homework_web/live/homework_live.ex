defmodule CaptainHomeworkWeb.HomeworkLive do
  use CaptainHomeworkWeb, :live_view
  require Logger
  alias CaptainHomework.{Study, Exams, AI, Uploads, Repo, Resources}
  alias CaptainHomework.Study.Page
  alias CaptainHomework.Exams.Flashcards
  import CaptainHomeworkWeb.QuestionComponents
  import CaptainHomeworkWeb.FlashcardComponents
  import CaptainHomeworkWeb.GenerationComponents
  import Ecto.Query
  alias CaptainHomeworkWeb.ProfilePath
  import CaptainHomeworkWeb.ProfilePath, only: [child_path: 2]

  # LiveView requires a positive integer; the browser's largest safe integer removes
  # the application size ceiling without falling back to LiveView's default limit.
  @resource_upload_size 9_007_199_254_740_991

  @impl true
  def mount(_params, session, socket) do
    profiles =
      if session["shared"],
        do: [],
        else: CaptainHomework.Accounts.profiles(socket.assigns.account)

    profile = Enum.find(profiles, &(&1.id == session["profile_id"])) || List.first(profiles)

    socket =
      assign(socket,
        shared: false,
        share_url: nil,
        share_mode: nil,
        share_expires_at: nil,
        form: to_form(%{}),
        lesson_form: lesson_form(),
        resource_form: to_form(%{"url" => ""}, as: :resource),
        rename_resource_id: nil,
        rename_resource_form: nil,
        available_question_types: [],
        subjects_form: nil,
        profiles: profiles,
        profile: profile,
        subjects: Study.subjects(),
        counts: %{},
        exam_counts: %{},
        subject: nil,
        lesson: nil,
        lesson_tab: "controles",
        exam: nil,
        generation_elapsed_ms: 0,
        generation_question_ids: [],
        exam_refresh_timer: nil,
        exam_sources: %{},
        source_page: nil,
        source_return_modal: nil,
        extraction_source: nil,
        extraction_count: 1,
        extraction_form: to_form(%{"instructions" => ""}, as: :extraction),
        extraction_ref: nil,
        extraction_error: nil,
        lessons_empty?: true,
        modal: nil,
        language_error: nil,
        page_title: "Accueil",
        error: nil,
        busy: false,
        busy_text: nil,
        upload_log_progress: %{},
        question_count: 10,
        exam_format: "classic",
        question_types: [],
        instructions: "",
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
     |> stream_configure(:generation_questions, dom_id: & &1.id)
     |> stream(:generation_questions, [])
     |> allow_family_uploads(session["shared"])
     |> allow_upload(:answer_photo,
       accept: ~w(.jpg .jpeg .png .webp),
       max_entries: 1,
       max_file_size: 12_000_000
     )}
  end

  defp allow_family_uploads(socket, true), do: socket

  defp allow_family_uploads(socket, _) do
    socket
    |> allow_upload(:pages,
      accept: ~w(.jpg .jpeg .png .webp),
      max_entries: 20,
      max_file_size: 12_000_000
    )
    |> allow_upload(:examples,
      auto_upload: true,
      progress: &log_upload_progress/3,
      accept: ~w(.jpg .jpeg .png .webp),
      max_entries: 5,
      max_file_size: 12_000_000
    )
    |> allow_upload(:resources,
      auto_upload: true,
      progress: &log_upload_progress/3,
      accept: ~w(.pdf .jpg .jpeg .png .webp),
      max_entries: 5,
      max_file_size: @resource_upload_size
    )
  end

  @impl true
  def handle_params(params, url, socket) do
    profile =
      if params["child"] do
        Enum.find(socket.assigns.profiles, &ProfilePath.matches?(&1, params["child"])) ||
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
      action when action in [:settings, :subjects_settings, :subject_preferences] ->
        assign(socket,
          page_title: "Paramètres",
          subjects_form: subject_preferences_form(profile)
        )

      :home ->
        assign(socket,
          page_title: "Accueil",
          counts: Study.counts(profile.id),
          exam_counts: Study.exam_counts(profile.id),
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
          exam_format: "classic",
          question_count: 10,
          available_question_types: CaptainHomework.QuestionDefinitions.available(lesson.subject),
          question_types:
            CaptainHomework.QuestionDefinitions.available(lesson.subject)
            |> Enum.filter(
              &(&1.work_duration == "quick" and
                  CaptainHomework.QuestionDefinitions.mode_allowed?(&1, "classic") and
                  CaptainHomework.QuestionDefinitions.generation_supported?(&1))
            )
            |> Enum.map(& &1.id)
        )
        |> stream(:resources, lesson.resources, reset: true)

      :exam ->
        exam = Study.get_exam!(profile.id, params["id"])
        Exams.recover_stale(exam)
        exam = Study.get_exam!(profile.id, params["id"])
        socket = subscribe(socket, :exam, exam.id)

        socket = schedule_exam_refresh(socket, exam)

        assign(socket,
          exam: exam,
          generation_elapsed_ms: generation_elapsed_ms(exam),
          exam_sources: CaptainHomework.Exams.Sources.for_exam(exam, profile.id),
          lesson: Repo.preload(exam.lesson, :pages),
          subject: Study.subject!(exam.lesson.subject),
          answers: exam.answers,
          error: exam.error,
          page_title: "Contrôle"
        )
        |> stream_generation_history()
        |> configure_drawing_uploads()
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
  def handle_event("explain_language", %{"question" => id, "index" => index}, socket) do
    exam = socket.assigns.exam

    errors =
      if exam && exam.status == "completed",
        do: get_in(exam.corrections, [id, "language_errors"]) || [],
        else: []

    case Integer.parse(index) do
      {index, ""} when index >= 0 ->
        case Enum.at(errors, index) do
          nil -> {:noreply, socket}
          error -> {:noreply, assign(socket, modal: "language_error", language_error: error)}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("open_share", _, socket) do
    {:noreply, assign(socket, modal: "share_exam", share_url: nil, share_mode: nil, error: nil)}
  end

  def handle_event("open_generation_history", _, socket) do
    if not socket.assigns.shared and socket.assigns.exam.generation_history != [] do
      {:noreply, socket |> assign(modal: "generation_history") |> stream_generation_history(true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("create_share", %{"mode" => mode}, socket) do
    case CaptainHomework.ExamShares.create(
           socket.assigns.profile.id,
           socket.assigns.exam.id,
           mode
         ) do
      {:ok, share, token} ->
        {:noreply,
         assign(socket,
           share_url: url(~p"/partage/#{token}"),
           share_mode: mode,
           share_expires_at: share.expires_at,
           error: nil
         )}

      {:error, _} ->
        {:noreply, assign(socket, error: "Ce partage n’est pas encore disponible.")}
    end
  end

  def handle_event("open_modal", %{"modal" => "resource_url"}, socket) do
    {:noreply,
     assign(socket,
       modal: "resource_url",
       error: nil,
       resource_form: to_form(%{"url" => ""}, as: :resource)
     )}
  end

  def handle_event("open_modal", %{"modal" => "lesson"}, socket) do
    {:noreply, assign(socket, modal: "lesson", error: nil, lesson_form: lesson_form())}
  end

  def handle_event("open_modal", %{"modal" => modal}, socket),
    do: {:noreply, assign(socket, modal: modal, error: nil)}

  def handle_event("close_modal", _, %{assigns: %{modal: "source"}} = socket) do
    {:noreply,
     assign(socket,
       modal: socket.assigns.source_return_modal,
       source_page: nil,
       source_return_modal: nil
     )}
  end

  def handle_event("preview_page", %{"id" => id}, socket) do
    if socket.assigns.lesson && Enum.any?(socket.assigns.lesson.pages, &(&1.id == id)) do
      page = Study.get_page!(socket.assigns.profile.id, id)

      {:noreply,
       assign(socket,
         modal: "source",
         source_page: page,
         source_return_modal: socket.assigns.modal
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_modal", _, socket),
    do: {:noreply, assign(socket, modal: nil, error: nil, ocr_text: nil, source_page: nil)}

  def handle_event("open_source", %{"id" => id}, socket) do
    allowed? =
      socket.assigns.exam_sources
      |> Map.values()
      |> List.flatten()
      |> Enum.any?(&(&1.page_id == id))

    if allowed? do
      page = Study.get_page!(socket.assigns.profile.id, id)
      {:noreply, assign(socket, modal: "source", source_page: page)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("validate", _, socket), do: {:noreply, socket}

  def handle_event("validate_lesson", %{"lesson" => %{"title" => title}}, socket) do
    {:noreply, assign(socket, lesson_form: lesson_form(title))}
  end

  def handle_event("cancel_upload", %{"name" => name, "ref" => ref}, socket) do
    upload =
      case name do
        "pages" -> :pages
        "examples" -> :examples
        "resources" -> :resources
        "answer_photo" -> :answer_photo
        "drawing-" <> _ -> name
      end

    {:noreply, cancel_upload(socket, upload, ref)}
  end

  def handle_event("create_lesson", %{"lesson" => %{"title" => title}}, socket) do
    socket = assign(socket, lesson_form: lesson_form(title))
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

  def handle_event("retry_example", %{"id" => id}, socket) do
    page = Study.get_page!(socket.assigns.profile.id, id)

    if page.kind == "example" and page.processing_stage == nil,
      do: CaptainHomework.ExampleStyles.schedule(page)

    {:noreply, refresh_lesson(socket)}
  end

  def handle_event("upload_examples", _, socket) do
    Logger.info(
      "document_upload save_requested kind=examples lesson_id=#{socket.assigns.lesson.id} count=#{length(socket.assigns.uploads.examples.entries)}"
    )

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

  def handle_event("validate_resource_url", %{"resource" => params}, socket) do
    {:noreply, assign(socket, resource_form: to_form(params, as: :resource), error: nil)}
  end

  def handle_event("add_resource_url", %{"resource" => %{"url" => url}}, socket) do
    socket = assign(socket, resource_form: to_form(%{"url" => url}, as: :resource))

    case Resources.create_url(
           socket.assigns.profile.id,
           socket.assigns.lesson.id,
           String.trim(url)
         ) do
      {:ok, resource} ->
        launch_resource(resource)

        {:noreply,
         socket
         |> assign(resource_form: to_form(%{"url" => ""}, as: :resource), modal: nil, error: nil)
         |> refresh_lesson()}

      {:error, reason} ->
        {:noreply, assign(socket, error: AI.message(reason))}
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

  def handle_event("rename_resource", %{"id" => id}, socket) do
    resource = Enum.find(socket.assigns.lesson.resources, &(&1.id == id))

    if resource do
      form = Resources.change_title(resource, %{title: resource_title(resource)})

      {:noreply,
       assign(socket,
         modal: "rename_resource",
         rename_resource_id: resource.id,
         rename_resource_form: to_form(form, as: :resource)
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("save_resource_name", %{"resource" => attrs}, socket) do
    case Resources.rename(
           socket.assigns.profile.id,
           socket.assigns.lesson.id,
           socket.assigns.rename_resource_id,
           attrs
         ) do
      {:ok, _resource} ->
        {:noreply, socket |> assign(modal: nil) |> refresh_lesson()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, rename_resource_form: to_form(changeset, as: :resource))}

      {:error, :not_found} ->
        {:noreply, socket |> assign(modal: nil) |> put_flash(:error, "Ressource introuvable.")}
    end
  end

  def handle_event("delete_resource", %{"id" => id}, socket) do
    case Resources.delete(socket.assigns.profile.id, id) do
      {:ok, _} -> {:noreply, refresh_lesson(socket)}
      {:error, reason} -> {:noreply, put_flash(socket, :error, AI.message(reason))}
    end
  end

  def handle_event("open_resource_image", %{"id" => id}, socket) do
    cond do
      socket.assigns.extraction_ref && socket.assigns.extraction_source.id == id ->
        {:noreply, assign(socket, modal: "extract_illustrations")}

      socket.assigns.extraction_ref ->
        {:noreply, put_flash(socket, :info, "Une extraction est déjà en cours.")}

      true ->
        case Resources.Extraction.source(socket.assigns.profile.id, socket.assigns.lesson.id, id) do
          {:ok, page} ->
            {:noreply,
             assign(socket,
               modal: "extract_illustrations",
               extraction_source: page,
               extraction_count: 1,
               extraction_error: nil,
               extraction_form: to_form(%{"instructions" => ""}, as: :extraction)
             )}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, AI.message(reason))}
        end
    end
  end

  def handle_event(event, _, %{assigns: %{extraction_ref: ref}} = socket)
      when not is_nil(ref) and
             event in ["change_extraction_count", "configure_extraction", "extract_illustrations"],
      do: {:noreply, socket}

  def handle_event("change_extraction_count", %{"delta" => delta}, socket)
      when delta in ["-1", "1"] do
    count =
      (socket.assigns.extraction_count + String.to_integer(delta))
      |> max(1)

    {:noreply, assign(socket, extraction_count: count)}
  end

  def handle_event("configure_extraction", %{"extraction" => params}, socket) do
    {:noreply,
     assign(socket,
       extraction_form: to_form(Map.take(params, ["instructions"]), as: :extraction),
       extraction_error: nil
     )}
  end

  def handle_event("extract_illustrations", %{"extraction" => params}, socket) do
    profile_id = socket.assigns.profile.id
    source = socket.assigns.extraction_source
    count = socket.assigns.extraction_count
    instructions = params["instructions"] || ""
    owner = self()
    ref = make_ref()

    socket =
      assign(socket, extraction_form: to_form(%{"instructions" => instructions}, as: :extraction))

    if source && socket.assigns.modal == "extract_illustrations" do
      case Task.Supervisor.start_child(CaptainHomework.Tasks, fn ->
             result =
               Resources.Extraction.extract(
                 profile_id,
                 source.lesson_id,
                 source.id,
                 count,
                 instructions
               )

             send(owner, {:illustrations_extracted, ref, result})
           end) do
        {:ok, _} ->
          {:noreply, assign(socket, extraction_ref: ref, extraction_error: nil)}

        {:error, _} ->
          {:noreply,
           assign(socket, extraction_error: "L’extraction n’a pas pu démarrer. Réessaie.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete_resource_image", %{"id" => id}, socket) do
    case Resources.delete_image(socket.assigns.profile.id, socket.assigns.lesson.id, id) do
      {:ok, _} ->
        {:noreply, refresh_lesson(socket)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Cette image n’est plus disponible.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, AI.message(reason))}
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
    case Study.delete_lesson(socket.assigns.profile.id, socket.assigns.lesson.id) do
      {:ok, lesson} ->
        {:noreply,
         push_navigate(socket,
           to: child_path(socket.assigns.profile, ~p"/matieres/#{lesson.subject}")
         )}

      {:error, :not_empty} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Impossible de supprimer une leçon contenant des cours, des contrôles ou des ressources."
         )}
    end
  end

  def handle_event("redo_exam", _, socket) do
    case Exams.redo(socket.assigns.profile.id, socket.assigns.exam.id) do
      {:ok, exam} ->
        {:noreply,
         push_navigate(socket, to: child_path(socket.assigns.profile, ~p"/controles/#{exam.id}"))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Impossible de refaire ce contrôle pour le moment.")}
    end
  end

  def handle_event("delete_exam", _, socket) do
    case Study.delete_exam(
           socket.assigns.profile.id,
           socket.assigns.exam.id,
           socket.assigns.account
         ) do
      {:ok, exam} ->
        {:noreply,
         push_navigate(socket,
           to: child_path(socket.assigns.profile, ~p"/lecons/#{exam.lesson_id}")
         )}

      {:error, :already_submitted} ->
        {:noreply,
         put_flash(socket, :error, "Ce contrôle ne peut pas être supprimé dans son état actuel.")}
    end
  end

  def handle_event("move_page", %{"id" => id, "direction" => direction}, socket)
      when direction in ["previous", "next"] do
    case Study.move_page(socket.assigns.profile.id, socket.assigns.lesson.id, id, direction) do
      {:ok, _} ->
        {:noreply, refresh_lesson(socket)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Cette page n’est plus disponible.")}

      {:error, :unavailable} ->
        {:noreply, put_flash(socket, :error, "Attends la fin de l’analyse de cette ressource.")}
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

  def handle_event("configure_exam", params, socket) do
    {:noreply,
     assign(socket,
       instructions: params["instructions"] || socket.assigns.instructions,
       exam_format: selected_exam_format(params, socket),
       question_types: selected_question_types(params, socket)
     )}
  end

  def handle_event("change_count", %{"delta" => delta}, socket) do
    value = socket.assigns.question_count + String.to_integer(delta)
    {:noreply, assign(socket, question_count: value |> max(1) |> min(30))}
  end

  def handle_event(event, _, %{assigns: %{busy: true}} = socket)
      when event in ["generate_exam", "resume_generation"], do: {:noreply, socket}

  def handle_event("generate_exam", params, socket) do
    case Exams.generate(
           socket.assigns.profile.id,
           socket.assigns.lesson.id,
           socket.assigns.question_count,
           params["instructions"] || socket.assigns.instructions,
           question_types: selected_question_types(params, socket),
           format: selected_exam_format(params, socket),
           background: true
         ) do
      {:ok, exam} ->
        {:noreply,
         socket
         |> assign(error: nil, busy: true)
         |> push_navigate(to: child_path(socket.assigns.profile, ~p"/controles/#{exam.id}"))}

      {:error, reason} ->
        {:noreply, assign(socket, error: AI.message(reason))}
    end
  end

  def handle_event("resume_generation", _, socket) do
    case Exams.resume_generation(socket.assigns.profile.id, socket.assigns.exam.id,
           background: true
         ) do
      {:ok, _} -> {:noreply, socket |> assign(error: nil) |> refresh_exam()}
      {:error, reason} -> {:noreply, assign(socket, error: AI.message(reason))}
    end
  end

  def handle_event("order_answer", %{"id" => id, "action" => action}, socket) do
    case Study.order_answer(socket.assigns.profile.id, socket.assigns.exam.id, id, action) do
      {:ok, exam} ->
        {:noreply,
         assign(socket,
           exam: exam,
           answers: exam.answers,
           saved: System.system_time(:millisecond)
         )}

      {:error, _} ->
        {:noreply, refresh_exam(socket)}
    end
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

  def handle_event("validate_card", params, socket) do
    id = params["question_id"]
    answer = get_in(params, ["answers", id]) || ""

    case Flashcards.submit(socket.assigns.profile.id, socket.assigns.exam.id, id, answer) do
      {:ok, _} ->
        Process.send_after(self(), :refresh_exam, 2000)
        {:noreply, refresh_exam(socket)}

      {:error, _} ->
        {:noreply, refresh_exam(socket)}
    end
  end

  def handle_event("next_card", %{"id" => id}, socket) do
    case Flashcards.advance(socket.assigns.profile.id, socket.assigns.exam.id, id) do
      {:ok, exam} ->
        socket = refresh_exam(socket)

        if exam.status == "completed",
          do: {:noreply, socket},
          else: {:noreply, push_event(socket, "flashcard:advanced", %{})}

      {:error, _} ->
        {:noreply, push_event(refresh_exam(socket), "flashcard:advance-cancelled", %{})}
    end
  end

  def handle_event("confirm_submit", params, socket) do
    if drawing_upload_pending?(socket.assigns.uploads) do
      {:noreply,
       assign(socket, error: "Attends la fin de l’envoi de la photo avant de rendre ta copie.")}
    else
      answers = params["answers"] || socket.assigns.answers

      case Study.save_answers(socket.assigns.profile.id, socket.assigns.exam.id, answers) do
        {:ok, exam} ->
          {:noreply, assign(socket, exam: exam, answers: exam.answers, confirming: true)}

        {:error, _} ->
          {:noreply, socket |> assign(confirming: false) |> refresh_exam()}
      end
    end
  end

  def handle_event("cancel_submit", _, socket), do: {:noreply, assign(socket, confirming: false)}

  def handle_event("submit_exam", _, socket) do
    case Exams.submit(socket.assigns.profile.id, socket.assigns.exam.id, socket.assigns.answers) do
      {:ok, _} ->
        Process.send_after(self(), :refresh_exam, 2000)

        {:noreply,
         socket
         |> assign(confirming: false, error: nil)
         |> refresh_exam()
         |> push_event("exam-submitted", %{})}

      _ ->
        {:noreply, refresh_exam(socket)}
    end
  end

  def handle_event("remove_drawing_photo", %{"id" => id}, socket) do
    case CaptainHomework.Exams.PhotoAnswers.remove(
           socket.assigns.profile.id,
           socket.assigns.exam.id,
           id
         ) do
      {:ok, exam} -> {:noreply, assign(socket, exam: exam, answers: exam.answers, error: nil)}
      {:error, message} -> {:noreply, assign(socket, error: message)}
    end
  end

  def handle_event("open_ocr", %{"id" => id}, socket) do
    q = Enum.find(socket.assigns.exam.questions, &(&1["id"] == id))

    if q && q["type"] in ~w(long reading definition listening) &&
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
  def handle_async(:ocr_answer, {:ok, {:ok, text}}, socket),
    do: {:noreply, assign(socket, busy: false, ocr_text: text)}

  def handle_async(_, {:ok, {:error, reason}}, socket),
    do: {:noreply, assign(socket, busy: false, error: AI.message(reason))}

  def handle_async(_, {:exit, _}, socket),
    do: {:noreply, assign(socket, busy: false, error: "L’opération a été interrompue. Réessaie.")}

  @impl true
  def handle_info(
        {:illustrations_extracted, ref, result},
        %{assigns: %{extraction_ref: ref}} = socket
      ) do
    socket = assign(socket, extraction_ref: nil)

    case result do
      {:ok, pages} ->
        socket =
          if socket.assigns.lesson &&
               socket.assigns.lesson.id == socket.assigns.extraction_source.lesson_id,
             do: refresh_lesson(socket),
             else: socket

        socket =
          if socket.assigns.modal == "extract_illustrations",
            do: assign(socket, modal: nil),
            else: socket

        {:noreply,
         put_flash(
           socket,
           :info,
           "#{count_label(length(pages), "illustration extraite", "illustrations extraites")}. L’originale est conservée."
         )}

      {:error, reason} ->
        socket =
          if socket.assigns.modal == "extract_illustrations",
            do: assign(socket, extraction_error: AI.message(reason)),
            else: put_flash(socket, :error, AI.message(reason))

        {:noreply, socket}
    end
  end

  def handle_info({:illustrations_extracted, _, _}, socket), do: {:noreply, socket}

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

      {:noreply, schedule_exam_refresh(socket, socket.assigns.exam)}
    else
      {:noreply, socket}
    end
  end

  defp lesson_form(title \\ "") do
    %Study.Lesson{}
    |> Ecto.Changeset.change(title: title)
    |> to_form(as: :lesson)
  end

  defp refresh_lesson(socket) do
    lesson = Study.get_lesson!(socket.assigns.profile.id, socket.assigns.lesson.id)
    socket |> assign(lesson: lesson) |> stream(:resources, lesson.resources, reset: true)
  end

  # The shared LiveView only delegates exam interactions after checking its capability.
  def load_shared_exam(socket, exam, profile) do
    socket
    |> assign(
      shared: true,
      profile: profile,
      exam: exam,
      lesson: %{exam.lesson | pages: []},
      subject: Study.subject!(exam.lesson.subject),
      answers: exam.answers,
      exam_sources: %{},
      error: exam.error,
      page_title: "Contrôle partagé"
    )
    |> subscribe(:exam, exam.id)
    |> schedule_exam_refresh(exam)
    |> configure_drawing_uploads()
  end

  defp refresh_exam(socket) do
    exam = Study.get_exam!(socket.assigns.profile.id, socket.assigns.exam.id)
    Exams.recover_stale(exam)
    exam = Study.get_exam!(socket.assigns.profile.id, exam.id)

    assign(socket,
      exam: exam,
      generation_elapsed_ms: generation_elapsed_ms(exam),
      exam_sources:
        if(socket.assigns.shared,
          do: %{},
          else: CaptainHomework.Exams.Sources.for_exam(exam, socket.assigns.profile.id)
        ),
      answers: exam.answers,
      error: exam.error
    )
    |> stream_generation_history()
    |> configure_drawing_uploads()
  end

  defp stream_generation_history(socket, reset \\ false) do
    entries =
      if socket.assigns.shared, do: [], else: Exams.GenerationHistory.entries(socket.assigns.exam)

    ids = Enum.map(entries, & &1.id)
    old_ids = socket.assigns.generation_question_ids

    socket =
      Enum.reduce(old_ids -- ids, socket, &stream_delete_by_dom_id(&2, :generation_questions, &1))

    socket
    |> assign(generation_question_ids: ids)
    |> stream(:generation_questions, entries, reset: reset)
  end

  defp drawing_upload_pending?(uploads) do
    Enum.any?(uploads, fn
      {"drawing-" <> _, upload} -> upload.entries != []
      _ -> false
    end)
  end

  defp drawing_upload_name(exam, question_id), do: "drawing-#{exam.id}-#{question_id}"

  defp configure_drawing_uploads(socket) do
    exam = socket.assigns.exam

    if exam.status == "in_progress" and exam.format == "classic" do
      Enum.reduce(exam.questions, socket, fn question, acc ->
        name = drawing_upload_name(exam, question["id"])

        if question["type"] == "photo" and not Map.has_key?(acc.assigns.uploads, name) do
          allow_upload(acc, name,
            auto_upload: true,
            accept: ~w(.jpg .jpeg .png .webp),
            max_entries: 1,
            max_file_size: 12_000_000,
            progress: fn _name, entry, socket ->
              save_drawing_upload(socket, entry, exam.id, question["id"])
            end
          )
        else
          acc
        end
      end)
    else
      socket
    end
  end

  defp save_drawing_upload(socket, entry, exam_id, question_id) do
    if entry.done? do
      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok,
           CaptainHomework.Exams.PhotoAnswers.put(
             socket.assigns.profile.id,
             exam_id,
             question_id,
             path,
             entry.client_name
           )}
        end)

      case result do
        {:ok, exam} ->
          {:noreply, assign(socket, exam: exam, answers: exam.answers, error: nil)}

        {:error, message} ->
          {:noreply, assign(socket, error: message)}
      end
    else
      {:noreply, socket}
    end
  end

  defp log_upload_progress(name, entry, socket) do
    key = {name, entry.ref}
    bucket = div(entry.progress, 25)
    previous = Map.get(socket.assigns.upload_log_progress, key, -1)

    if bucket != previous do
      Logger.info(
        "document_upload progress kind=#{name} ref=#{entry.ref} bytes=#{entry.client_size} percent=#{entry.progress} done=#{entry.done?}"
      )
    end

    progress = Map.put(socket.assigns.upload_log_progress, key, bucket)
    {:noreply, assign(socket, upload_log_progress: progress)}
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
            Logger.info(
              "document_upload saved kind=#{kind} page_id=#{page.id} lesson_id=#{lesson.id}"
            )

            if kind == "lesson", do: launch_ocr(page)
            if kind == "example", do: CaptainHomework.ExampleStyles.schedule(page)
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

  defp resource_title(resource) do
    title = String.trim(resource.title || resource.filename || "")
    if String.downcase(title) in ["", "view"], do: "Ressource sans titre", else: title
  end

  defp resource_status(resource) do
    case resource.status do
      "error" -> "Import à reprendre"
      _ -> "Import et lecture en cours…"
    end
  end

  defp resource_pages(lesson, resource_id),
    do:
      Enum.filter(
        lesson.pages,
        &(&1.resource_id == resource_id and
            CaptainHomework.Exams.Illustrations.resource_content_page?(&1))
      )

  defp resource_images(lesson, resource_id),
    do: Enum.filter(lesson.pages, &(&1.resource_id == resource_id and &1.kind == "illustration"))

  defp launch_ocr(page) do
    work = fn ->
      CaptainHomework.ProcessingProgress.update(page, 10, "Lecture OCR")

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

      if updated = Repo.get(Page, page.id) do
        if updated.status == "ready" do
          case CaptainHomework.Catalogues.prepare_page(updated) do
            {:ok, _} -> CaptainHomework.ProcessingProgress.complete(updated)
            _ -> CaptainHomework.ProcessingProgress.clear(updated)
          end
        else
          CaptainHomework.ProcessingProgress.clear(updated)
        end
      end

      Phoenix.PubSub.broadcast(
        CaptainHomework.PubSub,
        "lesson:#{page.lesson_id}",
        :lesson_updated
      )
    end

    if AI.configured?() do
      page
      |> Page.changeset(%{status: "pending", error: nil})
      |> Ecto.Changeset.change(processing_progress: 0, processing_stage: "Lecture OCR")
      |> Repo.update()

      Task.Supervisor.start_child(CaptainHomework.Tasks, work)
    else
      work.()
    end
  end

  defp question_type_groups(types) do
    for {duration, label} <- [
          {"quick", "Rapides"},
          {"medium", "Intermédiaires"},
          {"long", "Longues"}
        ] do
      sorted =
        types
        |> Enum.filter(&(&1.work_duration == duration))
        |> Enum.sort_by(fn type ->
          type.name
          |> String.downcase()
          |> String.normalize(:nfd)
          |> String.replace(~r/\p{Mn}/u, "")
        end)

      {duration, label, sorted}
    end
  end

  defp selected_question_types(params, socket) do
    allowed =
      socket.assigns.available_question_types
      |> Enum.filter(
        &(CaptainHomework.QuestionDefinitions.mode_allowed?(
            &1,
            selected_exam_format(params, socket)
          ) and CaptainHomework.QuestionDefinitions.generation_supported?(&1))
      )
      |> Enum.map(& &1.id)

    if Map.has_key?(params, "question_types") do
      params["question_types"]
      |> List.wrap()
      |> Enum.filter(&(&1 in allowed))
      |> Enum.uniq()
    else
      Enum.filter(socket.assigns.question_types, &(&1 in allowed))
    end
  end

  defp selected_exam_format(params, socket) do
    case params["format"] do
      "flashcard" -> "flashcard"
      "classic" -> "classic"
      _ -> socket.assigns.exam_format
    end
  end

  defp schedule_exam_refresh(socket, exam) do
    if timer = socket.assigns.exam_refresh_timer, do: Process.cancel_timer(timer)

    timer =
      if connected?(socket) and exam.status in ["grading", "generating"],
        do: Process.send_after(self(), :refresh_exam, 2000)

    assign(socket, :exam_refresh_timer, timer)
  end

  defp generation_elapsed_ms(%{
         status: "generating",
         generation_started_at: %DateTime{} = started
       }),
       do: max(DateTime.diff(DateTime.utc_now(), started, :millisecond), 0)

  defp generation_elapsed_ms(_), do: 0

  defp generation_stage_label(nil), do: "Préparation des questions …"

  defp generation_stage_label(stage) do
    label =
      stage
      |> String.replace(~r/^\d+ questions? prêtes? sur \d+ ·\s*/u, "")
      |> String.replace(~r/\s*(?:…|\.\.\.)$/u, "")
      |> String.trim()
      |> String.replace(~r/^correction de /iu, "Ajustement de ")

    label =
      if String.downcase(label) in ["préparation", "préparation en cours"],
        do: "Préparation des questions",
        else: label

    case String.next_grapheme(label) do
      {first, rest} -> String.upcase(first) <> rest <> " …"
      nil -> "Préparation des questions …"
    end
  end

  defp generation_duration(nil), do: "non enregistré"

  defp generation_duration(milliseconds) do
    seconds = max(div(milliseconds + 999, 1000), 1)

    cond do
      seconds < 60 -> "#{seconds} sec"
      seconds < 3600 -> "#{div(seconds, 60)}mn #{rem(seconds, 60)} sec"
      true -> "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}mn #{rem(seconds, 60)} sec"
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

  defp raw_score_label(exam) do
    {earned, total} = Exams.raw_score(exam)
    "#{number(earned)}/#{number(total)}"
  end

  defp score_class(score) when is_number(score) and score >= 16, do: "score-good"
  defp score_class(score) when is_number(score) and score >= 10, do: "score-average"
  defp score_class(_score), do: "score-low"

  defp type_name(type),
    do:
      %{
        "definition" => "Définition",
        "mcq" => "QCM",
        "cloze" => "Texte à trous",
        "reading" => "Compréhension",
        "listening" => "Compréhension orale",
        "long" => "Réponse rédigée",
        "diagram" => "Schéma",
        "photo" => "Dessin en photo",
        "ordering" => "Classement chronologique"
      }[type]

  defp readable_text(text), do: Regex.replace(~r/\{\{([^}]+)\}\}/, text, "_____ (\\1) _____")

  defp page_status(page) do
    case page.status do
      "pending" -> "Lecture en cours…"
      "error" -> "Texte à vérifier"
      _ -> "Texte reconnu"
    end
  end

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

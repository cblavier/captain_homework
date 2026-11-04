defmodule CaptainHomeworkWeb.QuestionTypesLive do
  use CaptainHomeworkWeb, :live_view
  alias CaptainHomework.{QuestionDefinitions, Study}
  alias CaptainHomework.Study.QuestionDefinition
  alias CaptainHomeworkWeb.ProfilePath
  import CaptainHomeworkWeb.ProfilePath, only: [child_path: 2]
  import CaptainHomeworkWeb.QuestionTypeComponents

  @filter_keys ~w(search subject mode)

  @impl true
  def mount(_params, session, socket) do
    profiles = Study.profiles()
    profile = Enum.find(profiles, &(&1.id == session["profile_id"])) || List.first(profiles)

    {:ok,
     socket
     |> assign(
       profile: profile,
       profiles: profiles,
       form: to_form(%{}),
       filters: %{},
       modal: nil,
       delete_type: nil,
       type: nil,
       tab: "definition",
       preview_mode: "classic",
       preview_subject: nil,
       preview_corrected: false,
       preview_ordering_answer: "",
       page_title: "Types de questions"
     )
     |> stream(:types, [])}
  end

  @impl true
  def handle_params(params, _url, socket) do
    profile =
      if params["child"], do: ProfilePath.find(params["child"]), else: socket.assigns.profile

    if is_nil(profile), do: raise(Ecto.NoResultsError, queryable: Study.Profile)
    filters = normalize_filters(params)
    socket = assign(socket, profile: profile, modal: nil, filters: filters)

    if !params["child"] do
      suffix =
        case socket.assigns.live_action do
          :index -> ""
          :new -> "/nouveau"
          :edit -> "/" <> params["id"]
        end

      {:noreply, push_navigate(socket, to: types_path(profile, filters, suffix))}
    else
      case socket.assigns.live_action do
        :index ->
          {:noreply, reload(socket, filters)}

        action ->
          type =
            if action == :new,
              do: %QuestionDefinition{},
              else: QuestionDefinitions.get!(params["id"])

          mode = if "flashcard" in type.modes, do: "flashcard", else: "classic"

          example = %{
            "prompt" =>
              type.example["prompt"] || type.instruction || "Écris la consigne de cette question.",
            "text" => type.example["text"] || "",
            "document" =>
              "Chaque matin, les habitants du village traversent la rivière pour rejoindre leurs champs. Le soir, ils se retrouvent sur la place pour échanger leurs récoltes.\n\nLes maisons sont regroupées près du pont. Un chemin relie le village aux terres cultivées."
          }

          {:noreply,
           socket
           |> assign(
             type: type,
             tab: "definition",
             preview_mode: mode,
             example: example,
             example_form: to_form(example, as: :example),
             preview_corrected: false,
             preview_ordering_answer: ""
           )
           |> edit_form(QuestionDefinitions.change(type))}
      end
    end
  end

  defp reload(socket, filters) do
    types = QuestionDefinitions.list(filters)

    socket
    |> assign(
      filters: filters,
      filter_form: to_form(filters, as: :filter),
      type_count: length(types)
    )
    |> stream(:types, types, reset: true)
  end

  defp normalize_filters(params),
    do:
      params |> Map.take(@filter_keys) |> Map.reject(fn {_, v} -> not is_binary(v) or v == "" end)

  defp types_path(profile, filters, suffix \\ "") do
    path = child_path(profile, "/parametres/types" <> suffix)
    if filters == %{}, do: path, else: path <> "?" <> URI.encode_query(filters)
  end

  defp edit_form(socket, cs) do
    type = Ecto.Changeset.apply_changes(cs)

    subject =
      if socket.assigns.preview_subject in type.subjects,
        do: socket.assigns.preview_subject,
        else: Enum.find_value(Study.subjects(), fn s -> if s.id in type.subjects, do: s.id end)

    assign(socket,
      type_form: to_form(cs, as: :type),
      preview_type: type,
      preview_subject: subject,
      preview_subject_form: to_form(%{"subject" => subject})
    )
  end

  @impl true
  def handle_event("preview_subject", %{"subject" => subject}, socket) do
    if subject in socket.assigns.preview_type.subjects do
      {:noreply,
       assign(socket,
         preview_subject: subject,
         preview_subject_form: to_form(%{"subject" => subject}),
         preview_corrected: false
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("filter", %{"filter" => filters}, socket) do
    {:noreply,
     push_patch(socket,
       to: types_path(socket.assigns.profile, normalize_filters(filters)),
       replace: true
     )}
  end

  def handle_event("tab", %{"tab" => tab}, socket) when tab in ~w(definition aides),
    do: {:noreply, assign(socket, tab: tab)}

  def handle_event("validate_type", %{"type" => attrs}, socket) do
    cs = QuestionDefinitions.change(socket.assigns.type, attrs) |> Map.put(:action, :validate)
    {:noreply, socket |> clear_flash(:error) |> edit_form(cs) |> assign(preview_corrected: false)}
  end

  def handle_event("save_type", %{"type" => attrs}, socket) do
    case QuestionDefinitions.save(socket.assigns.type, attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Type de question enregistré.")
         |> push_navigate(to: types_path(socket.assigns.profile, socket.assigns.filters))}

      {:error, cs} ->
        message =
          case Keyword.get(cs.errors, :name_key) do
            {message, _} -> message
            nil -> "Impossible d’enregistrer ce type. Vérifie les champs du formulaire."
          end

        {:noreply,
         socket
         |> edit_form(cs)
         |> assign(tab: "definition")
         |> put_flash(:error, message)}
    end
  end

  def handle_event("example", %{"example" => attrs}, socket) do
    example = Map.merge(socket.assigns.example, Map.take(attrs, ~w(prompt text document)))

    {:noreply,
     assign(socket,
       example: example,
       preview_ordering_answer: "",
       example_form: to_form(example, as: :example),
       preview_corrected: false
     )}
  end

  def handle_event("preview_mode", %{"mode" => mode}, socket) when mode in ~w(classic flashcard),
    do: {:noreply, assign(socket, preview_mode: mode, preview_corrected: false)}

  def handle_event("order_answer", %{"id" => "preview", "action" => action}, socket) do
    options = CaptainHomework.Exams.Ordering.example_options(socket.assigns.example["text"] || "")

    answer =
      CaptainHomework.Exams.Ordering.update(
        socket.assigns.preview_ordering_answer,
        options,
        action
      )

    {:noreply, assign(socket, preview_ordering_answer: answer)}
  end

  def handle_event("preview_answer", _, socket), do: {:noreply, socket}

  def handle_event("preview_validate", _, socket),
    do: {:noreply, assign(socket, preview_corrected: true)}

  def handle_event("preview_back", _, socket),
    do: {:noreply, assign(socket, preview_corrected: false)}

  def handle_event("ask_delete", %{"id" => id}, socket),
    do: {:noreply, assign(socket, modal: "delete", delete_type: QuestionDefinitions.get!(id))}

  def handle_event("close_modal", _, socket),
    do: {:noreply, assign(socket, modal: nil, delete_type: nil)}

  def handle_event(
        "confirm_delete",
        _,
        %{assigns: %{delete_type: %QuestionDefinition{id: id}}} = socket
      ) do
    case QuestionDefinitions.delete(id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Type supprimé.")
         |> push_navigate(to: types_path(socket.assigns.profile, socket.assigns.filters))}

      {:error, _} ->
        {:noreply,
         socket |> assign(modal: nil) |> put_flash(:error, "Impossible de supprimer ce type.")}
    end
  end

  defp response_label(kind),
    do:
      Enum.find_value(QuestionDefinition.response_options(), kind, fn {label, value} ->
        if kind == value, do: label
      end)

  defp duration_label(value),
    do:
      Enum.find_value(CaptainHomework.WorkDuration.options(), value, fn {id, label, _} ->
        if id == value, do: label
      end)

  defp subject_names(ids),
    do:
      Study.subjects()
      |> Enum.filter(&(&1.id in ids))
      |> Enum.map_join(" · ", &Study.subject_short_name/1)
end

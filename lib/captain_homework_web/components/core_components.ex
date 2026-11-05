defmodule CaptainHomeworkWeb.CoreComponents do
  @moduledoc "Shared controls and layout elements used across the application."
  use Phoenix.Component
  import CaptainHomework.Text
  alias Phoenix.LiveView.JS
  import CaptainHomeworkWeb.ProfilePath, only: [child_path: 2]

  use Phoenix.VerifiedRoutes,
    endpoint: CaptainHomeworkWeb.Endpoint,
    router: CaptainHomeworkWeb.Router,
    statics: CaptainHomeworkWeb.static_paths()

  attr :id, :string, required: true
  attr :value, :integer, required: true
  attr :min, :integer, default: 1
  attr :max, :integer, default: 30
  attr :unbounded, :boolean, default: false
  attr :event, :string, required: true
  attr :label, :string, required: true
  attr :disabled, :boolean, default: false

  def count_stepper(assigns) do
    ~H"""
    <div class="count-row">
      <label class="form-field-label" for={@id}>{@label}</label>
      <div class="stepper" role="group" aria-label={@label}>
        <button
          id={@id <> "-minus"}
          type="button"
          phx-click={@event}
          phx-value-delta="-1"
          disabled={@disabled or @value <= @min}
          aria-label={"Diminuer : #{@label}"}
        >
          <.icon name="minus" />
        </button>
        <output id={@id} aria-live="polite">{@value}</output>
        <button
          id={@id <> "-plus"}
          type="button"
          phx-click={@event}
          phx-value-delta="1"
          disabled={@disabled or (not @unbounded and @value >= @max)}
          aria-label={"Augmenter : #{@label}"}
        >
          <.icon name="plus" />
        </button>
      </div>
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true

  def field_errors(assigns) do
    ~H"""
    <p :for={{message, opts} <- @field.errors} class="error" role="alert">
      {Enum.reduce(opts, message, fn {key, value}, text ->
        String.replace(text, "%{#{key}}", to_string(value))
      end)}
    </p>
    """
  end

  attr :field, Phoenix.HTML.FormField, default: nil
  attr :id, :string, default: nil
  attr :name, :string, default: nil
  attr :value, :any, default: nil
  attr :label, :string, default: nil
  attr :type, :string, default: "text"
  attr :options, :list, default: []
  attr :class, :any, default: nil
  attr :wrapper, :boolean, default: true

  attr :rest, :global,
    include:
      ~w(rows maxlength minlength placeholder required autocomplete autocorrect autocapitalize spellcheck writingsuggestions autofocus disabled readonly min max step pattern multiple size)

  def input(assigns) do
    assigns =
      if assigns.field do
        assign(assigns,
          id: assigns.id || assigns.field.id,
          name: assigns.name || assigns.field.name,
          value: if(is_nil(assigns.value), do: assigns.field.value, else: assigns.value)
        )
      else
        assigns
      end

    ~H"""
    <div :if={@wrapper} class="form-field">
      <label :if={@label} for={@id} class="form-field-label">{@label}</label>
      <.form_control
        id={@id}
        name={@name}
        value={@value}
        type={@type}
        options={@options}
        class={@class}
        rest={@rest}
      />
      <.field_errors :if={@field} field={@field} />
    </div>
    <.form_control
      :if={!@wrapper}
      id={@id}
      name={@name}
      value={@value}
      type={@type}
      options={@options}
      class={@class}
      rest={@rest}
    />
    """
  end

  defp form_control(assigns) do
    assigns =
      if assigns.type in ["text", "textarea", "search"] do
        defaults = %{autocorrect: "on", spellcheck: "true", writingsuggestions: "true"}
        assign(assigns, :rest, Map.merge(defaults, assigns.rest))
      else
        assigns
      end

    ~H"""
    <span :if={@type == "select"} class="select-control">
      <select id={@id} name={@name} class={@class} {@rest}>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <.icon name="chevron-down" />
    </span>
    <textarea :if={@type == "textarea"} id={@id} name={@name} class={@class} {@rest}>{@value}</textarea>
    <input
      :if={@type not in ["select", "textarea"]}
      id={@id}
      name={@name}
      value={@value}
      type={@type}
      class={@class}
      {@rest}
    />
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :question_id, :string, required: true
  attr :options, :list, required: true
  attr :value, :any, default: ""
  attr :disabled, :boolean, default: false

  def ordering_input(assigns) do
    assigns =
      assign(
        assigns,
        :selected,
        CaptainHomework.Exams.Ordering.sequence(assigns.value, assigns.options)
      )

    ~H"""
    <div id={@id} class="ordering-input">
      <input type="hidden" name={@name} value={Enum.join(@selected, ", ")} />
      <p id={"#{@id}-help"} class="ordering-help">
        Clique sur les événements du plus ancien au plus récent.
      </p>
      <div
        class="ordering-options"
        role="group"
        aria-describedby={"#{@id}-help"}
        aria-label="Événements à classer"
      >
        <button
          :for={{option, index} <- Enum.with_index(@options, 1)}
          id={"#{@id}-choice-#{index}"}
          type="button"
          class={["ordering-choice", to_string(index) in @selected && "selected"]}
          phx-click="order_answer"
          phx-value-id={@question_id}
          phx-value-action={index}
          disabled={@disabled}
          aria-pressed={to_string(to_string(index) in @selected)}
          aria-label={"Événement #{index} : #{option}"}
        >
          <span class="ordering-number">{index}</span>
          <span class="ordering-label">{option}</span>
          <span :if={to_string(index) in @selected} class="ordering-rank">
            {Enum.find_index(@selected, &(&1 == to_string(index))) + 1}<sup>{if List.first(@selected) == to_string(index), do: "er", else: "e"}</sup>
          </span>
        </button>
      </div>
      <div
        id={"#{@id}-sequence"}
        class="ordering-feedback"
        role="status"
        aria-live="polite"
        aria-atomic="true"
      >
        <span class="ordering-caption">Ton ordre</span>
        <span :if={@selected == []} class="ordering-empty">À toi de commencer</span>
        <ol :if={@selected != []} class="ordering-sequence" aria-label="Ordre choisi">
          <li :for={{number, index} <- Enum.with_index(@selected)}>
            <span :if={index > 0} aria-hidden="true" class="ordering-arrow">→</span>
            <span class="ordering-number" title={Enum.at(@options, String.to_integer(number) - 1)}>
              {number}
            </span>
          </li>
        </ol>
        <span :if={@selected != []} class="ordering-count">
          {length(@selected)} / {length(@options)}
        </span>
      </div>
      <div class="ordering-actions">
        <button
          id={"#{@id}-undo"}
          type="button"
          class="button text-button"
          phx-click="order_answer"
          phx-value-id={@question_id}
          phx-value-action="undo"
          disabled={@disabled or @selected == []}
        >
          Annuler le dernier
        </button>
        <button
          id={"#{@id}-clear"}
          type="button"
          class="button text-button"
          phx-click="order_answer"
          phx-value-id={@question_id}
          phx-value-action="clear"
          disabled={@disabled or @selected == []}
        >
          Recommencer
        </button>
      </div>
    </div>
    """
  end

  attr :prompt, :string, required: true
  attr :type_label, :string, required: true
  attr :index, :integer, default: 1
  attr :points, :integer, default: 1

  def question_heading(assigns) do
    ~H"""
    <div class="question-meta">
      <span class="question-number">{@index}</span>
      <span>{@type_label}</span>
      <span class="points">{count_label(@points, "point", "points")}</span>
    </div>
    <h2>{@prompt}</h2>
    """
  end

  attr :text, :string, required: true

  def question_text(assigns) do
    ~H"""
    <div class="reading-text" phx-no-format>{@text}</div>
    """
  end

  attr :subject, :string, required: true
  attr :prompt, :string, required: true
  attr :id, :string, default: nil

  def flashcard_heading(assigns) do
    ~H"""
    <div class="flashcard-eyebrow">{@subject}</div>
    <h2 id={@id} class="flashcard-prompt">{@prompt}</h2>
    """
  end

  attr :name, :string, required: true
  attr :class, :string, default: ""

  def icon(assigns) do
    ~H"""
    <svg
      class={["icon", @class]}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      stroke-width="1.65"
      stroke-linecap="round"
      stroke-linejoin="round"
      aria-hidden="true"
    >
      <g :if={@name == "home"}>
        <path d="m3 10 9-7 9 7M5 9v12h5v-7h4v7h5V9" />
      </g>
      <g :if={@name == "book"}>
        <path d="M12 6C8 3 4 4 2 5v15c3-2 7-2 10 0 3-2 7-2 10 0V5c-3-2-7-2-10 1Z" /><path d="M12 6v14M5 8l4 1M5 12l4 1M15 9l4-1M15 13l4-1" />
      </g>
      <g :if={@name == "globe"}>
        <circle cx="12" cy="12" r="9" /><ellipse cx="12" cy="12" rx="4" ry="9" /><path d="M3 12h18M5 6.5c5 2 9 2 14 0M5 17.5c5-2 9-2 14 0" />
      </g>
      <g :if={@name == "language"}>
        <path d="M3 4h12M9 2v2M5 7c1 4 4 7 8 9M13 4c-1 7-5 11-11 14M13 21l5-12 5 12M15 17h6" />
      </g>
      <svg
        :if={@name == "flag-uk"}
        x="1"
        y="5"
        width="22"
        height="14"
        viewBox="0 0 60 36"
        overflow="hidden"
        stroke="none"
      >
        <path fill="#012169" d="M0 0h60v36H0z" />
        <path stroke="#fff" stroke-width="8" stroke-linecap="butt" d="m0 0 60 36M60 0 0 36" />
        <path stroke="#c8102e" stroke-width="3" stroke-linecap="butt" d="m0 0 60 36M60 0 0 36" />
        <path stroke="#fff" stroke-width="12" stroke-linecap="butt" d="M30 0v36M0 18h60" />
        <path stroke="#c8102e" stroke-width="7" stroke-linecap="butt" d="M30 0v36M0 18h60" />
      </svg>
      <g :if={@name == "flag-es"} stroke="none">
        <path fill="#aa151b" d="M1 5h22v14H1z" />
        <path fill="#f1bf00" d="M1 8.5h22v7H1z" />
        <path fill="#aa151b" d="M7 10h3v3a1.5 1.5 0 0 1-3 0zM7 9h3v.6H7z" />
      </g>
      <g :if={@name == "flag-fr"} stroke="none">
        <path fill="#fff" d="M1 5h22v14H1z" />
        <path fill="#000091" d="M1 5h7.333v14H1z" />
        <path fill="#e1000f" d="M15.667 5H23v14h-7.333z" />
      </g>
      <g :if={@name == "flask"}>
        <path d="M9 3h6M10 3v7L4 19a1.3 1.3 0 0 0 1 2h14a1.3 1.3 0 0 0 1-2l-6-9V3M7 15h10" />
        <circle cx="10" cy="18" r=".5" fill="currentColor" stroke="none" />
        <circle cx="13" cy="16.5" r=".5" fill="currentColor" stroke="none" />
      </g>
      <g :if={@name == "math"}>
        <rect x="4" y="2" width="16" height="20" rx="3" /><path d="M8 7h8M8 12h2M14 12h2M8 17h2M14 17h2" />
      </g>
      <g :if={@name == "leaf"}>
        <path d="M20 3C6 2 1 11 7 17c5 6 15 0 13-14Z M4 21L16 8M9 16l-1-5M13 12l5 1" />
      </g>
      <g :if={@name == "pencil"}><path d="m16 3 5 5-13 13H3v-5Z M14 5l5 5" /></g>
      <g :if={@name == "trash"}><path d="M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7M14 10v7" /></g>
      <g :if={@name == "microphone"}>
        <rect x="9" y="2" width="6" height="12" rx="3" /><path d="M5 10v2a7 7 0 0 0 14 0v-2M12 19v3M8 22h8" />
      </g>
      <path :if={@name == "plus"} d="M12 5v14M5 12h14" />
      <path :if={@name == "minus"} d="M5 12h14" />
      <path :if={@name == "chevron-down"} d="m6 9 6 6 6-6" />
      <g :if={@name == "keyboard"}>
        <rect x="2" y="5" width="20" height="14" rx="2" />
        <path d="M6 9h.01M10 9h.01M14 9h.01M18 9h.01M6 12h.01M10 12h.01M14 12h.01M18 12h.01M7 15h10" />
      </g>
      <path :if={@name == "arrows-right-left"} d="m16 3 4 4-4 4M4 7h16M8 21l-4-4 4-4m12 4H4" />
      <path :if={@name == "arrow"} d="m9 5 7 7-7 7" />
      <path :if={@name == "back"} d="m15 5-7 7 7 7" />
      <g :if={@name == "upload"}><path d="M12 16V3m-5 5 5-5 5 5M4 16v5h16v-5" /></g>
      <g :if={@name == "download"}><path d="M12 3v13m-5-5 5 5 5-5M4 16v5h16v-5" /></g>
      <g :if={@name == "camera"}>
        <path d="M3 6h4l2-3h6l2 3h4v15H3Z" /><circle cx="12" cy="13" r="4" />
      </g>
      <g :if={@name == "check"}><path d="m5 12 4 4L19 6" /></g>
      <g :if={@name == "warning"}>
        <circle cx="12" cy="12" r="9" /><path d="M12 7v6m0 4h.01" />
      </g>
      <g :if={@name == "paper"}><path d="M6 2h9l4 4v16H6Z M15 2v5h4M9 12h7M9 16h7" /></g>
      <g :if={@name == "close"}><path d="m6 6 12 12M6 18 18 6" /></g>
      <g :if={@name == "hero-cog-6-tooth"}>
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          d="M9.594 3.94c.09-.542.56-.94 1.11-.94h2.593c.55 0 1.02.398 1.11.94l.213 1.281c.063.374.313.686.645.87.074.04.147.083.22.127.325.196.72.257 1.075.124l1.217-.456a1.125 1.125 0 0 1 1.37.49l1.296 2.247a1.125 1.125 0 0 1-.26 1.431l-1.003.827c-.293.241-.438.613-.43.992a7.723 7.723 0 0 1 0 .255c-.008.378.137.75.43.991l1.004.827c.424.35.534.955.26 1.43l-1.298 2.247a1.125 1.125 0 0 1-1.369.491l-1.217-.456c-.355-.133-.75-.072-1.076.124a6.47 6.47 0 0 1-.22.128c-.331.183-.581.495-.644.869l-.213 1.281c-.09.543-.56.94-1.11.94h-2.594c-.55 0-1.019-.398-1.11-.94l-.213-1.281c-.062-.374-.312-.686-.644-.87a6.52 6.52 0 0 1-.22-.127c-.325-.196-.72-.257-1.076-.124l-1.217.456a1.125 1.125 0 0 1-1.369-.49l-1.297-2.247a1.125 1.125 0 0 1 .26-1.431l1.004-.827c.292-.24.437-.613.43-.991a6.932 6.932 0 0 1 0-.255c.007-.38-.138-.751-.43-.992l-1.004-.827a1.125 1.125 0 0 1-.26-1.43l1.297-2.247a1.125 1.125 0 0 1 1.37-.491l1.216.456c.356.133.751.072 1.076-.124.072-.044.146-.086.22-.128.332-.183.582-.495.644-.869l.214-1.28Z"
        />
        <path stroke-linecap="round" stroke-linejoin="round" d="M15 12a3 3 0 1 1-6 0 3 3 0 0 1 6 0Z" />
      </g>
      <g :if={@name == "hero-arrow-right-on-rectangle"}>
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          d="M15.75 9V5.25A2.25 2.25 0 0 0 13.5 3h-6a2.25 2.25 0 0 0-2.25 2.25v13.5A2.25 2.25 0 0 0 7.5 21h6a2.25 2.25 0 0 0 2.25-2.25V15m3 0 3-3m0 0-3-3m3 3H9"
        />
      </g>
      <g :if={@name == "user"}>
        <circle cx="12" cy="8" r="4" /><path d="M4 22v-3a8 8 0 0 1 16 0v3" />
      </g>
    </svg>
    """
  end

  attr :profile, :any, required: true
  attr :profiles, :list, required: true
  attr :form, :any, required: true
  attr :settings_active, :boolean, default: false

  def profile_header(assigns) do
    ~H"""
    <div class="identity-row">
      <details
        :if={@profile}
        id="child-picker"
        phx-click-away={JS.remove_attribute("open", to: "#child-picker")}
        phx-window-keydown={JS.remove_attribute("open", to: "#child-picker")}
        phx-key="Escape"
      >
        <summary id="child-picker-toggle" aria-label="Compte et paramètres">
          <span class="child-picker-avatar">
            <img
              :if={@profile.avatar}
              id="profile-avatar"
              src={@profile.avatar}
              decoding="sync"
              alt=""
            />
            <span :if={!@profile.avatar} id="profile-initial">{String.first(@profile.name)}</span>
          </span>
          <div id="child-identity">
            <p :if={@profile.school_name} id="school-name">
              {@profile.school_name}<span :if={@profile.class_name}> / {@profile.class_name}</span>
            </p>
            <div class="child-picker-name-row">
              <h1 id="child-name">{@profile.name}</h1>
              <.icon name="chevron-down" class="child-picker-chevron" />
            </div>
          </div>
        </summary>
        <div id="child-picker-panel">
          <.form for={@form} action={~p"/profil"} method="post" id="profile-switch">
            <ul aria-label="Enfants">
              <li :for={p <- @profiles} :if={p.id != @profile.id}>
                <button
                  id={"switch-profile-#{p.id}"}
                  type="submit"
                  name="profile_id"
                  value={p.id}
                  class="child-picker-option"
                >
                  <span class="child-option-avatar" data-child-theme={p.theme}>
                    <img :if={p.avatar} src={p.avatar} alt="" />
                    <span :if={!p.avatar}>{String.first(p.name)}</span>
                  </span>
                  <span>{p.name}</span>
                  <.icon name="arrows-right-left" />
                </button>
              </li>
            </ul>
            <p :if={length(@profiles) == 1} id="no-other-profiles" class="muted">
              Aucun autre espace disponible.
            </p>
          </.form>
          <hr class="child-picker-separator" />
          <.link
            navigate={child_path(@profile, ~p"/parametres")}
            id="settings-link"
            class="child-picker-option"
            aria-current={if @settings_active, do: "page"}
            phx-click={JS.remove_attribute("open", to: "#child-picker")}
          >
            <.icon name="hero-cog-6-tooth" />
            <span>Paramètres</span>
          </.link>
          <div class="child-picker-logout">
            <.link id="logout" href={~p"/session"} method="delete" class="child-picker-option">
              <.icon name="hero-arrow-right-on-rectangle" />
              <span>Se déconnecter</span>
            </.link>
          </div>
        </div>
      </details>
      <.link :if={!@profile} navigate={child_path(@profile, ~p"/parametres")} id="settings-link">
        Paramètres
      </.link>
    </div>
    """
  end

  @doc "Shared page title, matching Captain Notes."
  attr :id, :string, required: true
  attr :class, :any, default: nil
  slot :inner_block, required: true

  def page_title(assigns) do
    ~H"""
    <h2 id={@id} class={["page-title", @class]}>{render_slot(@inner_block)}</h2>
    """
  end

  attr :id, :string, required: true
  attr :ancestors, :list, required: true
  attr :subject, :map, default: nil
  attr :title_icon, :string, default: nil
  slot :inner_block, required: true
  slot :trailing

  def page_breadcrumb(assigns) do
    ~H"""
    <div class="page-breadcrumb" id={"#{@id}-breadcrumb"}>
      <div
        class={["breadcrumb-path", @ancestors == [] && "breadcrumb-path-root"]}
        style={"--breadcrumb-ancestor-count: #{length(@ancestors)}"}
      >
        <nav :if={@ancestors != []} aria-label="Fil d’Ariane">
          <ol>
            <li :for={{{label, path}, index} <- Enum.with_index(@ancestors)}>
              <.link
                navigate={path}
                class={if label == :home, do: "breadcrumb-home"}
                title={if label == :home, do: "Accueil", else: label}
              >
                <%= if label == :home do %>
                  <.icon name={if length(@ancestors) == 1, do: "back", else: "home"} />
                  <span class={if length(@ancestors) > 1, do: "sr-only", else: "breadcrumb-label"}>
                    {if length(@ancestors) == 1, do: "Retour à l’accueil", else: "Accueil"}
                  </span>
                <% else %>
                  <span class="breadcrumb-label">{label}</span>
                <% end %>
              </.link>
              <.icon
                :if={index < length(@ancestors) - 1}
                name="arrow"
                class="breadcrumb-separator"
              />
            </li>
          </ol>
        </nav>
        <div class="breadcrumb-title" aria-current="page">
          <div
            :if={@subject || @title_icon}
            class={["icon-tile small", if(@subject, do: @subject.color, else: "home-icon-tile")]}
            aria-hidden="true"
          >
            <.icon name={if @subject, do: @subject.icon, else: @title_icon} />
          </div>
          <.page_title id={@id}>{render_slot(@inner_block)}</.page_title>
          <div :if={@trailing != []} class="breadcrumb-trailing">{render_slot(@trailing)}</div>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :percent, :integer, required: true
  attr :stage, :string, required: true

  def processing_progress(assigns) do
    ~H"""
    <span id={@id} class="processing-progress" role="status" aria-live="polite">
      <span class="spinner" aria-hidden="true" />
      <strong title="Avancement total estimé">≈ {@percent} %</strong>
      <span>{@stage}</span>
    </span>
    """
  end

  @doc "A themed dropdown for both LiveView and ordinary HTML forms."
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :options, :list, required: true
  attr :value, :string, default: nil
  attr :disabled, :boolean, default: false

  def dropdown(assigns) do
    selected =
      Enum.find(assigns.options, fn {_, value} -> value == assigns.value end) ||
        List.first(assigns.options)

    assigns = assign(assigns, :selected, selected)

    ~H"""
    <details id={@id <> "-picker"} class="themed-dropdown" data-dropdown>
      <summary id={@id} aria-label={@label}>
        <span data-dropdown-label>{if @selected, do: elem(@selected, 0)}</span>
        <.icon name="hero-chevron-down" class="size-4 shrink-0" />
      </summary>
      <div class="dropdown-options" role="group" aria-label={@label}>
        <label :for={{label, value} <- @options} class="dropdown-option">
          <input
            type="radio"
            name={@name}
            value={value}
            checked={@selected && value == elem(@selected, 1)}
            disabled={@disabled}
          />
          <span data-option-label>{label}</span>
          <.icon name="hero-check" class="size-4 dropdown-check" />
        </label>
      </div>
    </details>
    """
  end

  attr :href, :string, default: "/"

  def brand(assigns) do
    ~H"""
    <a class="brand" href={@href} aria-label="Captain Homework — accueil">
      <img src="/images/logo.svg" width="44" height="44" alt="" aria-hidden="true" />
      <span>Captain<br /><strong>Homework</strong></span>
    </a>
    """
  end

  attr :id, :string, default: "modal"
  attr :title, :string, required: true
  slot :inner_block, required: true

  def modal(assigns) do
    ~H"""
    <div
      class="modal-shade"
      id={@id}
      phx-hook="Dialog"
      role="dialog"
      aria-modal="true"
      aria-labelledby={@id <> "-title"}
      phx-window-keydown="close_modal"
      phx-key="Escape"
    >
      <.focus_wrap id={@id <> "-focus"} class="modal-panel">
        <div class="section-heading">
          <h2 id={@id <> "-title"}>{@title}</h2>
          <button type="button" class="icon-button" phx-click="close_modal" aria-label="Fermer">
            <.icon name="close" />
          </button>
        </div>
        {render_slot(@inner_block)}
      </.focus_wrap>
    </div>
    """
  end

  attr :question, :map, required: true
  attr :exam, :map, default: nil
  attr :profile, :map, default: nil
  attr :sources, :list, default: nil

  def question_images(assigns) do
    sources =
      assigns.sources ||
        Enum.map(assigns.question["images"] || [], fn asset ->
          %{
            id: asset["id"],
            src:
              CaptainHomeworkWeb.ProfilePath.child_path(
                assigns.profile,
                "/controles/#{assigns.exam.id}/images/#{asset["id"]}"
              ),
            alt: "Illustration originale de l’exercice"
          }
        end)

    assigns = assign(assigns, sources: sources)

    ~H"""
    <div :if={@sources != []} class="question-illustrations">
      <img
        :for={asset <- @sources}
        id={"question-image-#{@question["id"]}-#{asset.id}"}
        src={asset.src}
        alt={asset.alt}
      />
    </div>
    """
  end

  attr :question, :map, required: true
  attr :exam, :map, default: nil
  attr :profile, :map, default: nil
  attr :src, :string, default: nil

  def question_audio(assigns) do
    src =
      assigns.src ||
        if assigns.question["type"] == "listening" and is_map(assigns.question["audio"]) do
          CaptainHomeworkWeb.ProfilePath.child_path(
            assigns.profile,
            "/controles/#{assigns.exam.id}/audio/#{assigns.question["audio"]["id"]}"
          )
        end

    assigns = assign(assigns, src: src)

    ~H"""
    <audio
      :if={@src}
      id={"question-audio-#{@question["id"]}"}
      class="question-audio"
      controls
      preload="metadata"
      aria-label="Extrait à écouter (voix générée par IA)"
      src={@src}
    />
    """
  end

  attr :question, :map, required: true

  def diagram(assigns) do
    ~H"""
    <svg class="diagram" viewBox="0 0 500 300" role="img" aria-label="Schéma à légender">
      <g :for={node <- @question["diagram"]["nodes"]}>
        <rect
          :if={node["shape"] == "rect"}
          x={node["x"]}
          y={node["y"]}
          width={node["width"]}
          height={node["height"]}
          rx="8"
          fill="#f1f5fa"
          stroke="#566b83"
          stroke-width="2"
        />
        <ellipse
          :if={node["shape"] == "ellipse"}
          cx={node["x"] + node["width"] / 2}
          cy={node["y"] + node["height"] / 2}
          rx={node["width"] / 2}
          ry={node["height"] / 2}
          fill="#f1f5fa"
          stroke="#566b83"
          stroke-width="2"
        />
        <text
          x={node["x"] + node["width"] / 2}
          y={node["y"] + node["height"] / 2 + 6}
          text-anchor="middle"
          fill="#263a5b"
          font-size="18"
        >
          {node["label"]}
        </text>
      </g>
    </svg>
    """
  end

  attr :prefix, :string, required: true
  attr :page_id, :string, required: true
  attr :index, :integer, required: true
  attr :count, :integer, required: true
  attr :label, :string, required: true
  attr :disabled, :boolean, default: false

  def page_order_actions(assigns) do
    ~H"""
    <div class="page-order-actions">
      <button
        id={"#{@prefix}-previous-#{@page_id}"}
        type="button"
        class="icon-button"
        phx-click="move_page"
        phx-value-id={@page_id}
        phx-value-direction="previous"
        disabled={@disabled or @index == 1}
        aria-label={"Déplacer #{@label} avant la précédente"}
        title="Déplacer avant"
      >
        <.icon name="back" />
      </button>
      <button
        id={"#{@prefix}-next-#{@page_id}"}
        type="button"
        class="icon-button"
        phx-click="move_page"
        phx-value-id={@page_id}
        phx-value-direction="next"
        disabled={@disabled or @index == @count}
        aria-label={"Déplacer #{@label} après la suivante"}
        title="Déplacer après"
      >
        <.icon name="arrow" />
      </button>
    </div>
    """
  end
end

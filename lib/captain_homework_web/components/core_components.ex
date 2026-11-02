defmodule CaptainHomeworkWeb.CoreComponents do
  use Phoenix.Component
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
      <g :if={@name == "book"}>
        <path d="M12 6C8 3 4 4 2 5v15c3-2 7-2 10 0 3-2 7-2 10 0V5c-3-2-7-2-10 1Z" /><path d="M12 6v14M5 8l4 1M5 12l4 1M15 9l4-1M15 13l4-1" />
      </g>
      <g :if={@name == "globe"}>
        <circle cx="12" cy="12" r="9" /><ellipse cx="12" cy="12" rx="4" ry="9" /><path d="M3 12h18M5 6.5c5 2 9 2 14 0M5 17.5c5-2 9-2 14 0" />
      </g>
      <g :if={@name == "language"}>
        <path d="M3 4h12M9 2v2M5 7c1 4 4 7 8 9M13 4c-1 7-5 11-11 14M13 21l5-12 5 12M15 17h6" />
      </g>
      <g :if={@name == "math"}>
        <rect x="4" y="2" width="16" height="20" rx="3" /><path d="M8 7h8M8 12h2M14 12h2M8 17h2M14 17h2" />
      </g>
      <g :if={@name == "leaf"}>
        <path d="M20 3C6 2 1 11 7 17c5 6 15 0 13-14Z M4 21L16 8M9 16l-1-5M13 12l5 1" />
      </g>
      <path :if={@name == "plus"} d="M12 5v14M5 12h14" />
      <path :if={@name == "minus"} d="M5 12h14" />
      <path :if={@name == "chevron-down"} d="m6 9 6 6 6-6" />
      <path :if={@name == "arrows-right-left"} d="m16 3 4 4-4 4M4 7h16M8 21l-4-4 4-4m12 4H4" />
      <path :if={@name == "arrow"} d="m9 5 7 7-7 7" />
      <path :if={@name == "back"} d="m15 5-7 7 7 7" />
      <g :if={@name == "upload"}><path d="M12 16V3m-5 5 5-5 5 5M4 16v5h16v-5" /></g>
      <g :if={@name == "camera"}>
        <path d="M3 6h4l2-3h6l2 3h4v15H3Z" /><circle cx="12" cy="13" r="4" />
      </g>
      <g :if={@name == "check"}><path d="m5 12 4 4L19 6" /></g>
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
  slot :inner_block, required: true
  slot :trailing

  def page_breadcrumb(assigns) do
    ~H"""
    <div class="page-breadcrumb" id={"#{@id}-breadcrumb"}>
      <nav :if={@ancestors != []} aria-label="Fil d’Ariane">
        <ol>
          <li :for={{{label, path}, index} <- Enum.with_index(@ancestors)}>
            <.link navigate={path}>{label}</.link>
            <.icon
              :if={index < length(@ancestors) - 1}
              name="arrow"
              class="breadcrumb-separator"
            />
          </li>
        </ol>
      </nav>
      <div class="breadcrumb-title" aria-current="page">
        <div :if={@subject} class={["icon-tile small", @subject.color]} aria-hidden="true">
          <.icon name={@subject.icon} />
        </div>
        <.page_title id={@id}>{render_slot(@inner_block)}</.page_title>
        <div :if={@trailing != []} class="breadcrumb-trailing">{render_slot(@trailing)}</div>
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
  attr :exam, :map, required: true
  attr :profile, :map, required: true

  def question_images(assigns) do
    ~H"""
    <div :if={Map.get(@question, "images", []) != []} class="question-illustrations">
      <img
        :for={asset <- Map.get(@question, "images", [])}
        id={"question-image-#{@question["id"]}-#{asset["id"]}"}
        src={
          CaptainHomeworkWeb.ProfilePath.child_path(
            @profile,
            "/controles/#{@exam.id}/images/#{asset["id"]}"
          )
        }
        alt="Illustration originale de l’exercice"
      />
    </div>
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
end

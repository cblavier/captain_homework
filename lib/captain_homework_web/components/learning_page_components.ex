defmodule CaptainHomeworkWeb.LearningPageComponents do
  use CaptainHomeworkWeb, :html
  alias CaptainHomework.Study.Pages
  alias CaptainHomeworkWeb.ProfilePath

  attr :stream, :any, required: true
  attr :profile, :any, required: true
  attr :lesson, :any, required: true
  attr :tab, :string, required: true
  attr :count, :integer, required: true

  def gallery(assigns) do
    ~H"""
    <div id="learning-pages" class="pages-grid learning-pages-grid" phx-update="stream">
      <.page_card :for={{dom_id, page} <- @stream} id={dom_id} page={page} count={@count}>
        <.link
          patch={ProfilePath.child_path(@profile, "/lecons/#{@lesson.id}") <> "?onglet=#{@tab}&page=#{page.id}"}
          id={"open-page-#{page.id}"}
          class="page-preview learning-page-preview"
        >
          <img
            :if={String.starts_with?(page.content_type, "image/")}
            src={ProfilePath.child_path(@profile, "/pages/#{page.id}")}
            alt={Pages.name(page)}
            loading="lazy"
          />
          <div :if={!String.starts_with?(page.content_type, "image/")} class="learning-text-preview">
            <.icon name="paper" />
            <p>{String.slice(page.text, 0, 240)}</p>
          </div>
        </.link>
        <p :if={page.status == "error"} class="error">{page.error}</p>
      </.page_card>
    </div>
    """
  end

  attr :stream, :any, required: true
  attr :profile, :any, required: true
  attr :count, :integer, required: true

  attr :id, :string, default: "page-illustrations"
  attr :unresolved, :boolean, default: false

  def illustrations(assigns) do
    ~H"""
    <div id={@id} class="pages-grid resource-illustration-grid" phx-update="stream">
      <.page_card
        :for={{dom_id, page} <- @stream}
        id={dom_id}
        page={page}
        count={@count}
        illustration
        unresolved={@unresolved}
      >
        <div class="page-thumbnail">
          <button
            id={"open-resource-image-#{page.id}"}
            type="button"
            class="page-preview"
            phx-click="preview_page"
            phx-value-id={page.id}
            aria-label={"Agrandir #{Pages.name(page)}"}
          >
            <img
              src={ProfilePath.child_path(@profile, "/pages/#{page.id}")}
              alt={Pages.name(page)}
              loading="lazy"
            />
          </button>
        </div>
      </.page_card>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :page, :any, required: true
  attr :count, :integer, required: true
  attr :illustration, :boolean, default: false
  attr :unresolved, :boolean, default: false
  slot :inner_block, required: true

  def page_card(assigns) do
    ~H"""
    <article
      id={@id}
      class={["page-card learning-card", @illustration && "resource-illustration-card"]}
    >
      <header
        id={"drag-page-#{@page.id}"}
        class="learning-card-bar learning-card-header"
        phx-hook="PageDrag"
        data-page-id={@page.id}
        draggable={Pages.available?(@page) and not @unresolved}
      >
        <.processing_progress
          :if={@page.status == "pending" or @page.processing_stage != nil}
          id={"page-progress-#{@page.id}"}
          stage={@page.processing_stage || "Lecture OCR"}
        />
        <span
          :if={@page.status != "pending" and @page.processing_stage == nil}
          class="learning-card-name"
          title={Pages.name(@page)}
        >
          {Pages.name(@page)}
        </span>
        <button
          :if={@page.status != "pending" and @page.processing_stage == nil}
          id={"rename-page-#{@page.id}"}
          type="button"
          class="icon-button"
          phx-click="rename_page"
          phx-value-id={@page.id}
          aria-label={"Renommer #{Pages.name(@page)}"}
        >
          <.icon name="pencil" />
        </button>
      </header>
      <div class="learning-card-content">{render_slot(@inner_block)}</div>
      <footer class="learning-card-bar learning-card-footer">
        <span class="learning-card-number">{@page.gallery_index}</span>
        <div class="resource-illustration-actions">
          <button
            :if={@unresolved}
            id={"attach-illustration-#{@page.id}"}
            class="button text-button"
            phx-click="attach_illustration"
            phx-value-id={@page.id}
          >
            Rattacher
          </button>
          <.page_order_actions
            :if={!@unresolved}
            prefix={if @illustration, do: "resource-image", else: "page"}
            page_id={@page.id}
            index={@page.gallery_index}
            count={@count}
            label={Pages.name(@page)}
          />
          <button
            id={
              if @illustration,
                do: "delete-resource-image-#{@page.id}",
                else: "delete-page-#{@page.id}"
            }
            type="button"
            class="icon-button"
            disabled={!Pages.available?(@page)}
            phx-click={if @illustration, do: "delete_resource_image", else: "delete_page"}
            phx-value-id={@page.id}
            data-confirm={
              if @illustration,
                do:
                  "Supprimer cette illustration et son texte reconnu ? La page originale est conservée.",
                else:
                  "Supprimer cette page, son texte et ses illustrations ? Les évaluations déjà créées sont conservées."
            }
            aria-label={if @illustration, do: "Supprimer l’illustration", else: "Supprimer la page"}
          >
            <.icon name="close" />
          </button>
        </div>
      </footer>
    </article>
    """
  end
end

defmodule CaptainHomeworkWeb.Layouts do
  use CaptainHomeworkWeb, :html
  embed_templates "layouts/*"
  attr :flash, :map, required: true
  attr :child_theme, :string, default: "blue"
  attr :immersive, :boolean, default: false
  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <.flash_group flash={@flash} />
    <div class={["page-shell", @immersive && "page-shell-immersive"]} data-child-theme={@child_theme}>
      {render_slot(@inner_block)}
      <footer :if={!@immersive} class="app-brand-footer">
        <span
          id="footer-logo"
          class="app-brand-logo"
          role="img"
          aria-label="Captain Homework"
        >
        </span>
      </footer>
    </div>
    """
  end

  def flash_group(assigns) do
    ~H"""
    <div id="flash-group" aria-live="polite">
      <div
        :for={{kind, message} <- @flash}
        id={"flash-#{kind}"}
        class={["app-flash", kind]}
        role="alert"
      >
        <.icon name={if kind == "error", do: "warning", else: "check"} />
        <div class="app-flash-content">
          <%= if is_map(message) do %>
            <p class="app-flash-title">{message["title"]}</p>
            <p>{message["message"]}</p>
            <.link
              navigate={message["href"]}
              phx-click={JS.push("lv:clear-flash", value: %{key: kind})}
            >
              Voir le contrôle
            </.link>
          <% else %>
            <p>{message}</p>
          <% end %>
        </div>
        <button
          id={"dismiss-flash-#{kind}"}
          type="button"
          aria-label="Fermer la notification"
          phx-click={JS.push("lv:clear-flash", value: %{key: kind})}
          class="app-flash-close"
        >
          <.icon name="close" />
        </button>
      </div>
    </div>
    """
  end
end

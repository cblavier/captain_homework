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
    <div
      :for={{kind, text} <- @flash}
      class={["toast", kind]}
      role="alert"
      phx-click={JS.push("lv:clear-flash", value: %{key: kind})}
    >
      {text}
    </div>
    """
  end
end

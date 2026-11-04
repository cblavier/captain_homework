defmodule CaptainHomeworkWeb.SymbolComponents do
  use Phoenix.Component
  import CaptainHomeworkWeb.CoreComponents, only: [icon: 1]
  alias CaptainHomework.Symbols

  attr :id, :string, required: true
  attr :context, :string, default: ""
  attr :label, :string, default: "Ta réponse"
  attr :disabled, :boolean, default: false
  slot :inner_block, required: true

  def symbol_answer(assigns) do
    assigns =
      assign(assigns,
        suggestions: Symbols.suggestions(assigns.context),
        families: Symbols.families()
      )

    ~H"""
    <div id={@id} class="symbol-answer">
      <span class="symbol-answer-label">{@label}</span>
      <div id={"#{@id}-fields"} class="symbol-answer-fields">
        {render_slot(@inner_block)}
      </div>
      <div
        id={"#{@id}-palette"}
        class="symbol-palette"
        phx-hook="SymbolPalette"
        phx-update="ignore"
        data-fields={"#{@id}-fields"}
        data-disabled={to_string(@disabled)}
        data-suggestions={Jason.encode!(Enum.map(@suggestions, &Tuple.to_list/1))}
      >
        <button
          id={"#{@id}-toggle"}
          type="button"
          class="symbol-toggle"
          data-symbol-toggle
          aria-expanded="false"
          aria-controls={"#{@id}-panel"}
          disabled={@disabled}
        >
          <.icon name="keyboard" /> Symboles <.icon name="chevron-down" />
        </button>
        <section id={"#{@id}-panel"} class="symbol-panel" aria-label="Insérer un symbole" hidden>
          <div class="symbol-suggestions" data-symbol-suggestions hidden>
            <span>Pour cet exercice</span>
            <div class="symbol-keys" data-suggested-keys />
          </div>
          <div class="symbol-families" role="group" aria-label="Famille de symboles">
            <button
              :for={{key, label, _} <- @families}
              type="button"
              data-symbol-family={key}
              aria-pressed={to_string(key == "usual")}
              aria-controls={"#{@id}-#{key}"}
            >
              {label}
            </button>
          </div>
          <div
            :for={{key, label, symbols} <- @families}
            id={"#{@id}-#{key}"}
            class="symbol-keys"
            data-symbol-group={key}
            aria-label={label}
            hidden={key != "usual"}
          >
            <button
              :for={{symbol, name} <- symbols}
              type="button"
              data-symbol={symbol}
              aria-label={"#{name} : #{symbol}"}
              title={name}
            >
              {symbol}
            </button>
          </div>
          <p data-symbol-feedback class="symbol-feedback" role="status" aria-live="polite" />
        </section>
      </div>
    </div>
    """
  end
end

const selector = 'textarea, input:not([type]), input[type="text"]'

export function insertSymbol(field, symbol, selection) {
  if (!field || field.readOnly || field.matches(':disabled')) return false
  const start = Math.min(selection?.start ?? field.value.length, field.value.length)
  const end = Math.max(start, Math.min(selection?.end ?? start, field.value.length))
  if (field.maxLength >= 0 && field.value.length - (end - start) + symbol.length > field.maxLength) return false
  field.setRangeText(symbol, start, end, 'end')
  field.dispatchEvent(new Event('input', {bubbles: true}))
  return true
}

export const SymbolPalette = {
  mounted() {
    this.fields = document.getElementById(this.el.dataset.fields)
    this.toggle = this.el.querySelector('[data-symbol-toggle]')
    this.panel = this.el.querySelector('.symbol-panel')
    this.feedback = this.el.querySelector('[data-symbol-feedback]')
    this.open = false
    this.selections = new Map()
    this.targetId = null
    this.remember = event => {
      const field = event.target
      if (!this.fields.contains(field) || !field.matches(selector)) return
      this.targetId = field.id
      this.selections.set(field.id, {start: field.selectionStart, end: field.selectionEnd})
    }
    this.selectionChanged = () => this.remember({target: document.activeElement})
    this.pointerDown = event => {
      if (event.target.closest('[data-symbol]')) event.preventDefault()
    }
    this.click = event => {
      const button = event.target.closest('button')
      if (!button || button.matches(':disabled') || this.el.dataset.disabled === 'true') return
      if (button === this.toggle) {
        this.setOpen(!this.open)
      } else if (button.dataset.symbolFamily) {
        const family = button.dataset.symbolFamily
        this.el.querySelectorAll('[data-symbol-family]').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.symbolFamily === family)))
        this.el.querySelectorAll('[data-symbol-group]').forEach(group => {group.hidden = group.dataset.symbolGroup !== family})
      } else if (button.dataset.symbol) {
        const fields = Array.from(this.fields.querySelectorAll(selector))
        const field = fields.find(f => f.id === this.targetId) || fields[0]
        if (!field) return
        const inserted = insertSymbol(field, button.dataset.symbol, this.selections.get(field.id))
        if (inserted) this.remember({target: field})
        this.feedback.textContent = inserted ? `${button.dataset.symbol} inséré` : 'Le champ est indisponible ou sa longueur maximale est atteinte.'
      }
    }
    this.keydown = event => {
      if (event.key === 'Escape' && this.open) {
        event.preventDefault()
        this.setOpen(false)
        this.toggle.focus({preventScroll: true})
      }
    }
    this.fieldEvents = ['focusin', 'input', 'select', 'keyup', 'pointerup']
    this.fieldEvents.forEach(name => this.fields.addEventListener(name, this.remember))
    document.addEventListener('selectionchange', this.selectionChanged)
    this.el.addEventListener('pointerdown', this.pointerDown)
    this.el.addEventListener('click', this.click)
    this.el.parentElement.addEventListener('keydown', this.keydown)
    this.updated()
  },
  setOpen(open) {
    this.open = open
    this.panel.hidden = !open
    this.toggle.setAttribute('aria-expanded', String(open))
    // The flashcard viewport measures its content after layout changes.
    window.dispatchEvent(new Event('resize'))
  },
  updated() {
    this.toggle.disabled = this.el.dataset.disabled === 'true'
    if (this.toggle.disabled) this.setOpen(false)
    const encoded = this.el.dataset.suggestions
    if (this.suggestions === encoded) return
    this.suggestions = encoded
    const symbols = JSON.parse(encoded || '[]')
    const keys = this.el.querySelector('[data-suggested-keys]')
    keys.replaceChildren()
    symbols.forEach(([symbol, name]) => {
      const button = document.createElement('button')
      button.type = 'button'
      button.dataset.symbol = symbol
      button.textContent = symbol
      button.title = name
      button.setAttribute('aria-label', `${name} : ${symbol}`)
      keys.append(button)
    })
    this.el.querySelector('[data-symbol-suggestions]').hidden = symbols.length === 0
  },
  destroyed() {
    this.fieldEvents.forEach(name => this.fields.removeEventListener(name, this.remember))
    document.removeEventListener('selectionchange', this.selectionChanged)
    this.el.removeEventListener('pointerdown', this.pointerDown)
    this.el.removeEventListener('click', this.click)
    this.el.parentElement?.removeEventListener('keydown', this.keydown)
  }
}

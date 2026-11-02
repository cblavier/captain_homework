// Keep a presentation-only copy above the live card while the next question arrives.
// The ignored overlay owns the copy; LiveView still owns all interactive content.
export const FlashcardStack = {
  mounted() {
    this.session = this.el.closest("#flashcard-session")
    this.animations = []
    this.departing = null
    this.onClick = event => {
      const button = event.target.closest("#next-card")
      if (!button) return
      if (this.departing) {
        event.preventDefault()
        event.stopImmediatePropagation()
        return
      }

      if (button.dataset.hasNext !== "true") return

      const back = this.session.querySelector(".flashcard-back")
      const copy = back.cloneNode(true)
      // No duplicate IDs, LiveView bindings or focusable controls in the snapshot.
      for (const element of [copy, ...copy.querySelectorAll("*")]) {
        for (const attribute of [...element.attributes]) {
          if (attribute.name === "id" || attribute.name.startsWith("phx-") || attribute.name.startsWith("data-phx-")) {
            element.removeAttribute(attribute.name)
          }
        }
      }
      copy.classList.remove("flashcard-back")
      copy.classList.add("flashcard-departing")
      copy.inert = true
      copy.setAttribute("aria-hidden", "true")
      this.departing = copy
      this.el.append(copy)
      copy.querySelector(".flashcard-content").scrollTop = back.querySelector(".flashcard-content").scrollTop
    }

    this.session.addEventListener("click", this.onClick, true)
    this.handleEvent("flashcard:advanced", () => this.revealNext())
    this.handleEvent("flashcard:advance-cancelled", () => this.clearDeparture())
  },
  revealNext() {
    const copy = this.departing
    if (!copy) return
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches || !copy.animate) {
      this.clearDeparture()
      return
    }

    // The server event arrives after the DOM patch: the real next question is
    // already beneath the snapshot, with its flip transition suppressed.
    const outgoing = copy.animate([
      {transform: "translateX(0) rotate(0deg)", opacity: 1},
      {transform: "translateX(-115%) rotate(-8deg)", opacity: 0}
    ], {duration: 550, easing: "cubic-bezier(.4,0,.2,1)", fill: "forwards"})
    const incoming = this.session.querySelector("#flashcard-inner").animate([
      {transform: "translateY(12px) scale(.97)"},
      {transform: "translateY(0) scale(1)"}
    ], {duration: 550, easing: "cubic-bezier(.2,.7,.2,1)"})
    this.animations = [outgoing, incoming]
    return Promise.all(this.animations.map(animation => animation.finished))
      .then(() => {
        if (this.departing === copy) this.clearDeparture()
      })
      .catch(() => {
        if (this.departing === copy) this.clearDeparture()
      })
  },
  clearDeparture() {
    const copy = this.departing
    this.departing = null
    for (const animation of this.animations) animation.cancel()
    this.animations = []
    copy?.remove()
  },
  disconnected() {
    this.clearDeparture()
  },
  destroyed() {
    this.clearDeparture()
    this.session.removeEventListener("click", this.onClick, true)
  }
}

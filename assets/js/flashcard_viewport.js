// This controller lives outside the rotating faces, so it survives card changes.
export const FlashcardViewport = {
  mounted() {
    this.session = this.el.closest("#flashcard-session")
    this.viewport = window.visualViewport
    this.frame = null
    this.measure = () => {
      cancelAnimationFrame(this.frame)
      this.frame = requestAnimationFrame(() => {
        const style = document.documentElement.style
        style.setProperty("--flashcard-viewport-height", `${this.viewport?.height ?? window.innerHeight}px`)
        style.setProperty("--flashcard-viewport-top", `${this.viewport?.offsetTop ?? 0}px`)
        // Read after resizing the card, including each step of the keyboard animation.
        this.revealAnswer()
      })
    }
    this.submit = event => {
      if (event.target.id !== "flashcard-answer") return
      // Release the keyboard before LiveView disables the inputs and flips the card.
      if (this.session.contains(document.activeElement)) document.activeElement.blur()
    }
    this.keydown = event => {
      if (event.key === "Enter" && event.target.matches("input:not([type=radio])")) {
        event.preventDefault()
      }
    }
    this.session.addEventListener("submit", this.submit, true)
    this.session.addEventListener("keydown", this.keydown)
    this.session.addEventListener("focusin", this.measure)
    this.viewport?.addEventListener("resize", this.measure)
    this.viewport?.addEventListener("scroll", this.measure)
    window.addEventListener("resize", this.measure)
    window.addEventListener("captain:theme-change", this.measure)
    window.scrollTo({top: 0, left: 0, behavior: "instant"})
    this.measure()
  },
  revealAnswer() {
    const input = document.activeElement
    if (!this.session.contains(input) ||
        !input.matches("#flashcard-response, #flashcard-answer .slot-inputs input") ||
        input.disabled || input.closest("[inert]")) return

    const content = input.closest(".flashcard-content")
    const bounds = content.getBoundingClientRect()
    if (!content.offsetHeight) return

    // Rectangles include the user's theme zoom; scroll distances do not.
    const zoom = bounds.height / content.offsetHeight
    if (zoom <= 0) return
    const margin = 12 * zoom
    const top = bounds.top + margin
    const bottom = bounds.bottom - margin
    if (bottom <= top) return

    const field = input.getBoundingClientRect()
    const delta = field.top < top
      ? field.top - top
      : Math.min(Math.max(0, field.bottom - bottom), field.top - top)

    // Scroll only the card, leaving its header and validation button in place.
    if (Math.abs(delta) > 1) content.scrollBy({top: delta / zoom, behavior: "instant"})
  },
  destroyed() {
    cancelAnimationFrame(this.frame)
    this.session.removeEventListener("submit", this.submit, true)
    this.session.removeEventListener("keydown", this.keydown)
    this.session.removeEventListener("focusin", this.measure)
    this.viewport?.removeEventListener("resize", this.measure)
    this.viewport?.removeEventListener("scroll", this.measure)
    window.removeEventListener("resize", this.measure)
    window.removeEventListener("captain:theme-change", this.measure)
    document.documentElement.style.removeProperty("--flashcard-viewport-height")
    document.documentElement.style.removeProperty("--flashcard-viewport-top")
    window.scrollTo({top: 0, left: 0, behavior: "instant"})
  }
}

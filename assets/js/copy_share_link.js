export const CopyShareLink = {
  mounted() {
    this.resetCopy = () => {
      clearTimeout(this.copyTimer)
      this.el.dataset.copied = "false"
      this.el.setAttribute("aria-label", "Copier le lien")
    }
    this.resetCopy()
    this.copy = async () => {
      const input = document.getElementById("share-url")
      const status = document.getElementById("share-copy-status")
      if (!input) return
      this.resetCopy()
      if (status) status.textContent = ""
      try {
        await navigator.clipboard.writeText(input.value)
        if (this.copyDestroyed) return
        this.el.dataset.copied = "true"
        this.el.setAttribute("aria-label", "Lien copié")
        clearTimeout(this.copyTimer)
        this.copyTimer = setTimeout(this.resetCopy, 3000)
      } catch {
        if (this.copyDestroyed) return
        input.focus()
        input.select()
        if (status) status.textContent = "Sélectionne et copie le lien dans le champ."
      }
    }
    this.el.addEventListener("click", this.copy)
  },
  updated() {
    this.resetCopy()
    const status = document.getElementById("share-copy-status")
    if (status) status.textContent = ""
  },
  destroyed() {
    this.copyDestroyed = true
    clearTimeout(this.copyTimer)
    this.el.removeEventListener("click", this.copy)
  }
}

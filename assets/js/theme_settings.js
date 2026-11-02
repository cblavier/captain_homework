export const ThemeSettings = {
  mounted() {
    this.sync = () => {
      const choice = window.captainTheme.read()
      this.el.querySelectorAll('input[name="theme"]').forEach(input => {
        input.checked = input.value === choice
      })
      const zoom = window.captainTheme.readZoom()
      this.el.querySelectorAll('input[name="zoom"]').forEach(input => {
        input.checked = input.value === zoom
      })
    }
    this.onChange = event => {
      if (event.target.name === "theme") window.captainTheme.set(event.target.value)
      if (event.target.name === "zoom") window.captainTheme.setZoom(event.target.value)
    }
    this.el.addEventListener("change", this.onChange)
    window.addEventListener("captain:theme-change", this.sync)
    this.sync()
  },
  destroyed() {
    this.el.removeEventListener("change", this.onChange)
    window.removeEventListener("captain:theme-change", this.sync)
  }
}

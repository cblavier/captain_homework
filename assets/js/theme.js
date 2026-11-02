// Loaded before the stylesheet to avoid a light flash when opening a dark page.
(() => {
  const media = window.matchMedia("(prefers-color-scheme: dark)")
  let memory
  let zoomMemory
  const zoomValues = {small: "0.9", normal: "1", large: "1.1"}
  const normalizeZoom = value => Object.hasOwn(zoomValues, value) ? value : "normal"
  const readZoom = () => {
    try { return normalizeZoom(localStorage.getItem("captain-zoom") ?? zoomMemory) }
    catch { return normalizeZoom(zoomMemory) }
  }
  const normalize = value => ["light", "dark", "system"].includes(value) ? value : "system"
  const read = () => {
    try { return normalize(localStorage.getItem("captain-theme") ?? memory) }
    catch { return normalize(memory) }
  }
  const apply = () => {
    const choice = read()
    const theme = choice === "dark" || (choice === "system" && media.matches) ? "dark" : "light"
    document.documentElement.dataset.theme = theme
    const zoom = zoomValues[readZoom()]
    document.documentElement.style.zoom = zoom
    document.documentElement.style.setProperty("--app-zoom", zoom)
    document.querySelector('meta[name="theme-color"]')?.setAttribute("content", theme === "dark" ? "#151a21" : "#ffffff")
    window.dispatchEvent(new Event("captain:theme-change"))
  }
  window.captainTheme = {
    read,
    readZoom,
    setZoom(value) {
      zoomMemory = normalizeZoom(value)
      try { localStorage.setItem("captain-zoom", zoomMemory) } catch {}
      apply()
    },
    set(value) {
      memory = normalize(value)
      try { localStorage.setItem("captain-theme", memory) } catch {}
      apply()
    }
  }
  media.addEventListener("change", apply)
  window.addEventListener("storage", event => {
    if (["captain-theme", "captain-zoom", null].includes(event.key)) apply()
  })
  apply()
})()

const viewport = document.querySelector('meta[name="viewport"]')
const defaultViewport = viewport?.getAttribute("content") || "width=device-width, initial-scale=1"
let zoomLocked = false

const syncZoom = () => {
  const active = !!document.querySelector("#flashcard-viewport")
  if (active === zoomLocked) return
  zoomLocked = active
  viewport?.setAttribute("content", active
    ? "width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no"
    : defaultViewport)
}

// Follow LiveView patches, including completion and navigation out of the player.
new MutationObserver(syncZoom).observe(document.body, {childList: true, subtree: true})
syncZoom()

const preventZoom = event => {
  if (zoomLocked && event.cancelable) event.preventDefault()
}

for (const name of ["gesturestart", "gesturechange"]) {
  document.addEventListener(name, preventZoom, {passive: false})
}

document.addEventListener("wheel", event => {
  if (event.ctrlKey) preventZoom(event)
}, {passive: false})

document.addEventListener("keydown", event => {
  if ((event.ctrlKey || event.metaKey) && !event.altKey && ["+", "=", "-", "0"].includes(event.key)) {
    preventZoom(event)
  }
})

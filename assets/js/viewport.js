const preventZoom = event => {
  if (event.cancelable) event.preventDefault()
}

// Safari exposes pinch gestures separately from pointer events.
for (const name of ["gesturestart", "gesturechange"]) {
  document.addEventListener(name, preventZoom, {passive: false})
}

// Trackpad pinch and Ctrl+wheel zoom; ordinary scrolling remains available.
document.addEventListener("wheel", event => {
  if (event.ctrlKey) preventZoom(event)
}, {passive: false})

document.addEventListener("keydown", event => {
  if ((event.ctrlKey || event.metaKey) && !event.altKey && ["+", "=", "-", "0"].includes(event.key)) {
    preventZoom(event)
  }
})

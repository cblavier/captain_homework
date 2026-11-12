const canvas = document.createElement("canvas")
const context = canvas.getContext("2d")

function resize(input) {
  const field = input.closest(".cloze-field")
  if (!field || !context) return
  const style = getComputedStyle(input)
  context.font = `${style.fontWeight} ${style.fontSize} ${style.fontFamily}`
  const text = input.value || input.placeholder || ""
  const spacing = Number.parseFloat(style.letterSpacing) || 0
  const width = context.measureText(text).width + Math.max(0, [...text].length - 1) * spacing
  field.style.setProperty("--cloze-text-width", `${Math.ceil(width)}px`)
}

let frame
function resizeAll() {
  cancelAnimationFrame(frame)
  frame = requestAnimationFrame(() => document.querySelectorAll(".cloze-input").forEach(resize))
}

document.addEventListener("input", event => {
  if (event.target.matches(".cloze-input")) resize(event.target)
})
window.addEventListener("phx:update", resizeAll)
window.addEventListener("resize", resizeAll)
document.fonts?.ready.then(resizeAll)
resizeAll()

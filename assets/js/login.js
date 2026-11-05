// The login form is a regular POST form, outside LiveView.
document.addEventListener("click", event => {
  const key = event.target.closest("#pin-form [data-pin-digit], #pin-form [data-pin-action]")
  if (!key) return
  const input = document.querySelector("#pin-form #pin")
  if (!input) return
  if (key.dataset.pinAction === "clear") input.value = ""
  else if (key.dataset.pinAction === "backspace") input.value = input.value.slice(0, -1)
  else input.value = input.value + key.dataset.pinDigit
  input.dispatchEvent(new Event("input", {bubbles: true}))
})

// Native events also work on the login form, which lives outside LiveView.
document.addEventListener("change", event => {
  const picker = event.target.closest("[data-dropdown]")
  if (!picker || !event.target.matches('input[type="radio"]')) return
  picker.querySelector("[data-dropdown-label]").textContent =
    event.target.closest("label").querySelector("[data-option-label]").textContent
  picker.open = false
  picker.querySelector("summary").focus()
  if (picker.id === "login-account-picker") {
    const pin = document.querySelector("#pin-form #pin")
    if (pin) pin.value = ""
  }
})
document.addEventListener("click", event => {
  document.querySelectorAll("[data-dropdown][open]").forEach(picker => {
    if (!picker.contains(event.target)) picker.open = false
  })
})
document.addEventListener("keydown", event => {
  if (event.key !== "Escape") return
  document.querySelectorAll("[data-dropdown][open]").forEach(picker => {
    picker.open = false
    picker.querySelector("summary").focus()
  })
})

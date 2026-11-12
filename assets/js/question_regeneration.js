let regenerationScroll = null
window.addEventListener("click", event => {
  const button = event.target.closest("[data-regenerate-question]")
  if (button) regenerationScroll = {id: button.dataset.regenerateQuestion, y: window.scrollY}
}, true)
window.addEventListener("phx:question-regeneration-started", event => {
  requestAnimationFrame(() => requestAnimationFrame(() => {
    if (regenerationScroll?.id === event.detail.id) {
      window.scrollTo({top: regenerationScroll.y, behavior: "instant"})
    } else {
      document.getElementById(`question-${event.detail.id}`)?.scrollIntoView({block: "start", behavior: "instant"})
    }
    regenerationScroll = null
  }))
})

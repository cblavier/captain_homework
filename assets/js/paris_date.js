export function formatParisDate(value) {
  const date = new Date(value)
  const options = {timeZone: "Europe/Paris"}
  const day = new Intl.DateTimeFormat("fr-FR", {...options, day: "2-digit", month: "2-digit", year: "numeric"}).format(date)
  const time = new Intl.DateTimeFormat("fr-FR", {...options, hour: "2-digit", minute: "2-digit", hourCycle: "h23"}).format(date)
  return `${day} à ${time}`
}

export const ParisDate = {
  mounted() { this.el.textContent = formatParisDate(this.el.dataset.date) },
  updated() { this.el.textContent = formatParisDate(this.el.dataset.date) }
}

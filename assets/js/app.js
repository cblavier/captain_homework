import "phoenix_html"
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import topbar from "../vendor/topbar"
import {ThemeSettings} from "./theme_settings"
import {ExamAnswers} from "./exam_answers"
import {FlashcardViewport} from "./flashcard_viewport"
import {FlashcardStack} from "./flashcard_stack"
import "./viewport"
const Hooks = {
  ThemeSettings,
  ExamAnswers,
  FlashcardViewport,
  FlashcardStack,
  Dialog: {
    mounted() {this.previousFocus = document.activeElement; (this.el.querySelector("input:not([type=hidden]),textarea") || this.el.querySelector("button"))?.focus(); document.body.style.overflow = "hidden"},
    destroyed() {document.body.style.overflow = ""; this.previousFocus?.focus()}
  },
  Saved: {
    mounted() {this.timer = null},
    updated() {clearTimeout(this.timer); this.el.classList.add("just-saved"); this.timer = setTimeout(() => this.el.classList.remove("just-saved"), 1200)},
    destroyed() {clearTimeout(this.timer)}
  }
}
const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {params: {_csrf_token: csrfToken}, hooks: Hooks})
topbar.config({barColors: {0: "#506d93"}, shadowColor: "transparent"})
window.addEventListener("phx:page-loading-start", () => topbar.show(200))
window.addEventListener("phx:page-loading-stop", () => topbar.hide())
window.addEventListener("phx:exam-submitted", () => {
  requestAnimationFrame(() => window.scrollTo({top: 0, left: 0, behavior: "instant"}))
})
liveSocket.connect()
window.liveSocket = liveSocket

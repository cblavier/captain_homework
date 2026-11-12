import {test} from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import vm from "node:vm"

const source = readFileSync(new URL("../../assets/js/question_regeneration.js", import.meta.url), "utf8")
function setup() {
  const events = new Map(), frames = [], scrolls = []
  const window = {scrollY: 1400, addEventListener: (name, fn) => events.set(name, fn), scrollTo: value => scrolls.push(value)}
  const document = {getElementById: id => ({scrollIntoView: value => scrolls.push({id, ...value})})}
  vm.runInNewContext(source, {window, document, requestAnimationFrame: fn => frames.push(fn)})
  return {events, frames, scrolls, window, flush() {while (frames.length) frames.shift()()}}
}
test("return to the scroll position captured before opening the modal, after DOM updates", () => {
  const env = setup()
  env.events.get("click")({target: {closest: () => ({dataset: {regenerateQuestion: "q5"}})}})
  env.window.scrollY = 0
  env.events.get("phx:question-regeneration-started")({detail: {id: "q5"}})
  assert.equal(env.scrolls.length, 0)
  env.flush()
  assert.equal(env.scrolls[0].top, 1400)
  assert.equal(env.scrolls[0].behavior, "instant")
})
test("without a captured click the regenerated question is brought into view", () => {
  const env = setup()
  env.events.get("phx:question-regeneration-started")({detail: {id: "q2"}})
  env.flush()
  assert.equal(env.scrolls[0].id, "question-q2")
})

import {test} from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import vm from "node:vm"

const source = readFileSync(new URL("../../assets/js/flashcard_viewport.js", import.meta.url), "utf8")

function environment(withViewport = true, zoom = 1) {
  const target = () => ({
    listeners: new Map(),
    addEventListener(name, callback) {this.listeners.set(name, callback)},
    removeEventListener(name, callback) {
      assert.equal(this.listeners.get(name), callback)
      this.listeners.delete(name)
    }
  })
  const properties = new Map()
  const style = {setProperty: (key, value) => properties.set(key, value), removeProperty: key => properties.delete(key)}
  const session = {...target(), contains: element => element === input}
  const content = {
    top: 100, bottom: 700, scrollTop: 0, scrolls: [],
    get offsetHeight() {return (this.bottom - this.top) / zoom},
    getBoundingClientRect() {return {top: this.top, bottom: this.bottom, height: this.bottom - this.top}},
    scrollBy({top, behavior}) {
      assert.equal(behavior, "instant")
      this.scrolls.push(top)
      this.scrollTop = Math.max(0, this.scrollTop + top)
    }
  }
  const input = {
    blurred: false, fieldTop: 500, height: 100, answerField: true, disabled: false, inert: false,
    blur() {this.blurred = true; document.activeElement = null},
    matches() {return this.answerField},
    closest(selector) {return selector === "[inert]" ? (this.inert ? {} : null) : content},
    getBoundingClientRect() {
      const top = this.fieldTop - content.scrollTop * zoom
      return {top, bottom: top + this.height * zoom, height: this.height * zoom}
    }
  }
  const viewport = {...target(), height: 800, offsetTop: 0}
  const window = {...target(), visualViewport: withViewport ? viewport : undefined, innerHeight: 700, scrollTo() {}}
  const document = {documentElement: {style}, activeElement: input}
  const frames = new Map()
  let frameId = 0
  const context = vm.createContext({window, document,
    requestAnimationFrame(callback) {frames.set(++frameId, callback); return frameId},
    cancelAnimationFrame(id) {frames.delete(id)}
  })
  vm.runInContext(source.replace("export const FlashcardViewport =", "globalThis.hook ="), context)
  const hook = {...context.hook, el: {closest: () => session}}
  const flush = () => {for (const [id, callback] of frames) {frames.delete(id); callback()}}
  hook.mounted()
  flush()
  return {hook, window, viewport, session, input, content, document, properties, frames, flush}
}

test("the player follows the visible area when the mobile keyboard opens", () => {
  const env = environment()
  assert.equal(env.properties.get("--flashcard-viewport-height"), "800px")
  env.viewport.height = 420
  env.viewport.offsetTop = 35
  env.content.bottom = 355
  env.viewport.listeners.get("resize")()
  env.viewport.listeners.get("scroll")()
  assert.equal(env.frames.size, 1)
  env.flush()
  assert.equal(env.properties.get("--flashcard-viewport-height"), "420px")
  assert.equal(env.properties.get("--flashcard-viewport-top"), "35px")
  assert.equal(env.input.getBoundingClientRect().bottom, env.content.bottom - 12)
  assert.equal(env.content.scrolls.length, 1)
  assert.equal(env.input.blurred, false)
  env.session.listeners.get("submit")({target: {id: "flashcard-answer"}})
  assert.equal(env.input.blurred, true)
})

test("focusing another answer scrolls it back into view and leaves visible fields still", () => {
  const env = environment()
  assert.equal(env.content.scrolls.length, 0)
  env.content.scrollTop = 450
  env.session.listeners.get("focusin")()
  env.flush()
  assert.equal(env.input.getBoundingClientRect().top, env.content.top + 12)
  assert.equal(env.content.scrolls.length, 1)
  env.session.listeners.get("focusin")()
  env.flush()
  assert.equal(env.content.scrolls.length, 1)
})

test("keyboard scrolling accounts for the user's theme zoom", () => {
  const env = environment(true, 0.8)
  env.content.bottom = 300
  env.viewport.listeners.get("resize")()
  env.flush()
  assert.ok(Math.abs(env.input.getBoundingClientRect().bottom - (300 - 12 * 0.8)) < 0.01)
  assert.equal(env.content.scrolls.length, 1)
})

test("a field taller than the visible area stays aligned at the top without oscillating", () => {
  const env = environment()
  env.content.bottom = 190
  env.viewport.listeners.get("resize")()
  env.flush()
  assert.equal(env.input.getBoundingClientRect().top, 112)
  env.viewport.listeners.get("scroll")()
  env.flush()
  assert.equal(env.content.scrolls.length, 1)
})

test("no scrolling is triggered by unrelated, disabled or hidden fields", () => {
  for (const state of ["answerField", "disabled", "inert", "outside"]) {
    const env = environment()
    env.content.bottom = 300
    if (state === "outside") env.document.activeElement = null
    else env.input[state] = state !== "answerField"
    env.viewport.listeners.get("resize")()
    env.flush()
    assert.equal(env.content.scrolls.length, 0)
  }
})

test("leaving the player removes viewport effects and pending updates", () => {
  const env = environment()
  env.viewport.listeners.get("resize")()
  env.hook.destroyed()
  env.flush()
  assert.equal(env.properties.size, 0)
  assert.equal(env.frames.size, 0)
  for (const target of [env.session, env.viewport, env.window]) assert.equal(target.listeners.size, 0)
})

test("browsers without VisualViewport use the window height", () => {
  const env = environment(false)
  assert.equal(env.properties.get("--flashcard-viewport-height"), "700px")
  env.window.innerHeight = 500
  env.window.listeners.get("resize")()
  env.flush()
  assert.equal(env.properties.get("--flashcard-viewport-height"), "500px")
  env.hook.destroyed()
})

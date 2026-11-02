import {test} from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import vm from "node:vm"

const source = readFileSync(new URL("../../assets/js/flashcard_viewport.js", import.meta.url), "utf8")

function environment(withViewport = true) {
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
  const input = {blurred: false, blur() {this.blurred = true}}
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
  return {hook, window, viewport, session, input, properties, frames, flush}
}

test("the player follows the visible area when the mobile keyboard opens", () => {
  const env = environment()
  assert.equal(env.properties.get("--flashcard-viewport-height"), "800px")
  env.viewport.height = 420
  env.viewport.offsetTop = 35
  env.viewport.listeners.get("resize")()
  env.viewport.listeners.get("scroll")()
  assert.equal(env.frames.size, 1)
  env.flush()
  assert.equal(env.properties.get("--flashcard-viewport-height"), "420px")
  assert.equal(env.properties.get("--flashcard-viewport-top"), "35px")
  assert.equal(env.input.blurred, false)
  env.session.listeners.get("submit")({target: {id: "flashcard-answer"}})
  assert.equal(env.input.blurred, true)
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

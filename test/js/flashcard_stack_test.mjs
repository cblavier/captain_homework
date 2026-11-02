import {test} from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import vm from "node:vm"

const source = readFileSync(new URL("../../assets/js/flashcard_stack.js", import.meta.url), "utf8")

function environment({reducedMotion = false, hasNext = true} = {}) {
  const listeners = new Map()
  const events = new Map()
  const animations = []
  const attributes = new Map([["id", "flashcard-correction"], ["phx-click", "next_card"], ["data-phx-id", "123"]])
  const classes = new Set(["flashcard-face", "flashcard-back"])
  const content = {scrollTop: 0}
  const overlay = {
    children: [],
    append(node) {this.children.push(node)},
    closest() {return session}
  }
  function animate(frames, options) {
    let resolve, reject
    const finished = new Promise((yes, no) => {resolve = yes; reject = no})
    const animation = {frames, options, finished, resolve, cancel() {reject(new Error("cancelled"))}}
    animations.push(animation)
    return animation
  }
  const copy = {
    get attributes() {return [...attributes.keys()].map(name => ({name}))},
    removeAttribute(name) {attributes.delete(name)},
    setAttribute(name, value) {attributes.set(name, value)},
    classList: {add(name) {classes.add(name)}, remove(name) {classes.delete(name)}},
    querySelectorAll() {return []},
    querySelector() {return content},
    remove() {overlay.children = overlay.children.filter(node => node !== this)},
    animate
  }
  const back = {cloneNode: () => copy, querySelector: () => ({scrollTop: 120})}
  const session = {
    querySelector(selector) {return selector === ".flashcard-back" ? back : {animate}},
    addEventListener(name, fn) {listeners.set(name, fn)},
    removeEventListener(name, fn) {assert.equal(listeners.get(name), fn); listeners.delete(name)}
  }
  const context = vm.createContext({window: {matchMedia: () => ({matches: reducedMotion})}})
  vm.runInContext(source.replace("export const FlashcardStack =", "globalThis.hook ="), context)
  const hook = {...context.hook, el: overlay, handleEvent(name, fn) {events.set(name, fn)}}
  hook.mounted()
  const click = () => {
    const event = {
      target: {closest: () => ({dataset: {hasNext: String(hasNext)}})},
      preventDefault() {this.prevented = true},
      stopImmediatePropagation() {this.stopped = true}
    }
    listeners.get("click")(event)
    return event
  }
  return {hook, events, click, overlay, animations, copy, attributes, classes, content, listeners}
}

test("the snapshot waits for the next question before sliding away", async () => {
  const env = environment()
  env.click()
  assert.equal(env.overlay.children.length, 1)
  assert.equal(env.animations.length, 0)
  assert.equal(env.copy.inert, true)
  assert.equal(env.attributes.has("id"), false)
  assert.equal(env.attributes.has("phx-click"), false)
  assert.equal(env.attributes.has("data-phx-id"), false)
  assert.equal(env.content.scrollTop, 120)
  const duplicate = env.click()
  assert.equal(duplicate.prevented, true)
  assert.equal(duplicate.stopped, true)
  const transition = env.events.get("flashcard:advanced")()
  assert.equal(env.animations.length, 2)
  for (const animation of env.animations) animation.resolve()
  await transition
  assert.equal(env.overlay.children.length, 0)
  assert.equal(env.hook.departing, null)
})

test("the final card keeps the separate transition to the results", () => {
  const env = environment({hasNext: false})
  assert.equal(env.click().prevented, undefined)
  assert.equal(env.overlay.children.length, 0)
})

test("reduced motion reveals the next card without animation", () => {
  const env = environment({reducedMotion: true})
  env.click()
  env.events.get("flashcard:advanced")()
  assert.equal(env.animations.length, 0)
  assert.equal(env.overlay.children.length, 0)
})

test("a rejected advance restores the live card and allows retrying", () => {
  const env = environment()
  env.click()
  env.events.get("flashcard:advance-cancelled")()
  assert.equal(env.overlay.children.length, 0)
  assert.equal(env.click().prevented, undefined)
  assert.equal(env.overlay.children.length, 1)
})

test("disconnecting or leaving cancels animations and removes the snapshot", async () => {
  const env = environment()
  env.click()
  env.events.get("flashcard:advanced")()
  env.hook.disconnected()
  await Promise.allSettled(env.animations.map(animation => animation.finished))
  assert.equal(env.overlay.children.length, 0)
  env.hook.destroyed()
  assert.equal(env.listeners.size, 0)
})

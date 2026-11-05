import {test} from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import vm from "node:vm"

const source = readFileSync(new URL("../../assets/js/viewport.js", import.meta.url), "utf8")

test("zoom is free outside flashcards and restored after completion or navigation", () => {
  let active = false
  let content = "width=device-width, initial-scale=1"
  let changed
  const listeners = new Map()
  const viewport = {getAttribute: () => content, setAttribute: (_, value) => {content = value}}
  const document = {
    body: {},
    querySelector: selector => selector.startsWith("meta") ? viewport : (active ? {} : null),
    addEventListener: (name, callback) => listeners.set(name, callback)
  }
  vm.runInNewContext(source, {document, MutationObserver: class {
    constructor(callback) {changed = callback}
    observe() {}
  }})
  const prevented = (name, options = {}) => {
    let result = false
    listeners.get(name)({cancelable: true, preventDefault() {result = true}, ...options})
    return result
  }
  for (const playing of [false, true, false, true, false]) {
    active = playing
    changed()
    assert.equal(content.includes("user-scalable=no"), playing)
    assert.equal(prevented("gesturestart"), playing)
    assert.equal(prevented("gesturechange"), playing)
    assert.equal(prevented("wheel", {ctrlKey: true}), playing)
    assert.equal(prevented("keydown", {metaKey: true, key: "+"}), playing)
    assert.equal(prevented("keydown", {ctrlKey: true, key: "-"}), playing)
    assert.equal(prevented("wheel"), false)
    assert.equal(prevented("keydown", {key: "+"}), false)
  }
  assert.equal(content, "width=device-width, initial-scale=1")
})

import {test} from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import vm from "node:vm"

const source = readFileSync(new URL("../../assets/js/theme.js", import.meta.url), "utf8")

function environment({stored = null, dark = false, blocked = false} = {}) {
  const listeners = {}
  const media = {matches: dark, addEventListener: (_, callback) => {media.change = callback}}
  const root = {dataset: {}, style: {setProperty(name, value) {this[name] = value}}}
  const meta = {setAttribute: (_, value) => {meta.color = value}}
  const storage = {
    getItem(key) {if (blocked) throw new Error("blocked"); return key === "captain-theme" ? stored : this.zoom ?? null},
    setItem(key, value) {if (blocked) throw new Error("blocked"); if (key === "captain-theme") stored = value; else this.zoom = value}
  }
  const window = {
    matchMedia: () => media,
    addEventListener: (name, callback) => {listeners[name] = callback},
    dispatchEvent: event => listeners[event.type]?.(event)
  }
  const document = {documentElement: root, querySelector: () => meta}
  vm.runInNewContext(source, {window, document, localStorage: storage, Event})
  return {window, root, media, meta, stored: () => stored, external(value) {
    stored = value
    listeners.storage({key: "captain-theme"})
  }}
}

test("system is the default and follows OS changes", () => {
  const env = environment({dark: true})
  assert.equal(env.window.captainTheme.read(), "system")
  assert.equal(env.root.dataset.theme, "dark")
  env.media.matches = false
  env.media.change()
  assert.equal(env.root.dataset.theme, "light")
})

test("explicit choice persists across reload and overrides the OS", () => {
  const env = environment({dark: true})
  env.window.captainTheme.set("light")
  env.media.change()
  assert.equal(env.root.dataset.theme, "light")
  assert.equal(env.stored(), "light")
  assert.equal(environment({stored: env.stored(), dark: true}).root.dataset.theme, "light")
  env.window.captainTheme.set("dark")
  assert.equal(env.meta.color, "#151a21")
  env.window.captainTheme.set("system")
  assert.equal(env.root.dataset.theme, "dark")
})

test("storage changes in another tab apply immediately", () => {
  const env = environment()
  env.external("dark")
  assert.equal(env.root.dataset.theme, "dark")
  env.external(null)
  assert.equal(env.root.dataset.theme, "light")
})

test("unavailable storage and invalid values do not break theme changes", () => {
  const env = environment({blocked: true})
  env.window.captainTheme.set("dark")
  assert.equal(env.root.dataset.theme, "dark")
  assert.equal(env.window.captainTheme.read(), "dark")
  const invalid = environment({stored: "invalid", dark: true})
  assert.equal(invalid.window.captainTheme.read(), "system")
  assert.equal(invalid.root.dataset.theme, "dark")
})

test("zoom uses Captain Notes levels and remains independent of theme", () => {
  const env = environment({stored: "dark"})
  assert.equal(env.root.style.zoom, "1")
  env.window.captainTheme.setZoom("small")
  assert.equal(env.root.style.zoom, "0.9")
  env.window.captainTheme.setZoom("large")
  env.window.captainTheme.set("light")
  assert.equal(env.root.style.zoom, "1.1")
  assert.equal(env.root.style["--app-zoom"], "1.1")
  env.window.captainTheme.setZoom("invalid")
  assert.equal(env.root.style.zoom, "1")
  const blocked = environment({blocked: true})
  blocked.window.captainTheme.setZoom("large")
  assert.equal(blocked.root.style.zoom, "1.1")
})

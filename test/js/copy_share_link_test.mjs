import {test} from 'node:test'
import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import vm from 'node:vm'

const source = readFileSync(new URL('../../assets/js/copy_share_link.js', import.meta.url), 'utf8')

function setup(clipboard) {
  const input = {value: 'https://homework.test/partage/first', focus() {this.focused = true}, select() {this.selected = true}}
  const status = {textContent: ''}
  const timers = new Map()
  let timerId = 0
  const context = vm.createContext({setTimeout(fn, ms) {const id = ++timerId; timers.set(id, {fn, ms}); return id}, clearTimeout(id) {timers.delete(id)}, navigator: {clipboard}, document: {getElementById: id => id === 'share-url' ? input : status}})
  vm.runInContext(source.replace('export const ', 'globalThis.'), context)
  const listeners = {}
  const hook = {...context.CopyShareLink, el: {dataset: {}, setAttribute(name, value) {this[name] = value}, addEventListener(event, fn) {listeners[event] = fn}, removeEventListener(event) {delete listeners[event]}}}
  hook.mounted()
  return {hook, input, status, listeners, timers}
}

test('copy uses the currently selected share URL after the mode changes', async () => {
  const copied = []
  const {hook, input, status, listeners} = setup({writeText: async text => copied.push(text)})
  await listeners.click()
  input.value = 'https://homework.test/partage/correction'
  hook.updated()
  assert.equal(status.textContent, '')
  await listeners.click()
  assert.deepEqual(copied, ['https://homework.test/partage/first', input.value])
  assert.equal(status.textContent, '')
  assert.equal(hook.el.dataset.copied, 'true')
  hook.destroyed()
  assert.equal(listeners.click, undefined)
})

test('clipboard denial leaves the URL selected and explains manual copying', async () => {
  const {input, status, listeners} = setup({writeText: async () => {throw new Error('denied')}})
  await listeners.click()
  assert.equal(input.focused, true)
  assert.equal(input.selected, true)
  assert.match(status.textContent, /copie le lien/)
})

test('check replaces the label for three seconds and repeated copies reset the timer', async () => {
  const {hook, listeners, timers} = setup({writeText: async () => {}})
  await listeners.click()
  assert.equal(hook.el.dataset.copied, 'true')
  assert.equal([...timers.values()][0].ms, 3000)
  await listeners.click()
  assert.equal(timers.size, 1)
  ;[...timers.values()][0].fn()
  assert.equal(hook.el.dataset.copied, 'false')
  await listeners.click()
  hook.destroyed()
  assert.equal(timers.size, 0)
})

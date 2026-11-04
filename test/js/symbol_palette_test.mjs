import {test} from 'node:test'
import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
const source = readFileSync(new URL('../../assets/js/symbol_palette.js', import.meta.url), 'utf8')
const {insertSymbol, SymbolPalette} = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`)
function field(value = '', attrs = {}) {
  const events = []
  return {value, maxLength: -1, readOnly: false, disabled: false, ...attrs,
    matches(selector) {return selector === ':disabled' ? this.disabled : true},
    dispatchEvent(event) {events.push({type: event.type, bubbles: event.bubbles, value: this.value})},
    setRangeText(symbol, start, end) {this.value = this.value.slice(0, start) + symbol + this.value.slice(end); this.selectionStart = this.selectionEnd = start + symbol.length}, events}
}
test('inserts at the cursor and emits the input event used by LiveView autosave', () => {
  const input = field('D  (AB)')
  assert.equal(insertSymbol(input, '∉', {start: 2, end: 2}), true)
  assert.equal(input.value, 'D ∉ (AB)')
  assert.equal(input.selectionStart, 3)
  assert.deepEqual(input.events, [{type: 'input', bubbles: true, value: 'D ∉ (AB)'}])
})
test('replaces selected text and inserts independent delimiters in multiline answers', () => {
  const input = field('Première ligne\n(AB)')
  const start = input.value.indexOf('(')
  insertSymbol(input, '[', {start, end: start + 1})
  insertSymbol(input, 'ñ', {start: input.value.length, end: input.value.length})
  assert.equal(input.value, 'Première ligne\n[AB)ñ')
})
test('never edits readonly, disabled or full fields, but allows replacing at the limit', () => {
  for (const attrs of [{readOnly: true}, {disabled: true}, {maxLength: 2}]) {
    const input = field('AB', attrs)
    assert.equal(insertSymbol(input, '∉'), false)
    assert.equal(input.value, 'AB')
    assert.equal(input.events.length, 0)
  }
  const input = field('AB', {maxLength: 2})
  assert.equal(insertSymbol(input, 'ñ', {start: 1, end: 2}), true)
  assert.equal(input.value, 'Añ')
})
test('clamps a remembered cursor after the text is shortened', () => {
  const input = field('D')
  insertSymbol(input, '∉', {start: 20, end: 30})
  assert.equal(input.value, 'D∉')
})
test('palette insertion targets the last selected field without stealing focus', () => {
  const one = field('AB', {id: 'one'}), two = field('CD', {id: 'two'})
  const hook = {fields: {querySelectorAll: () => [one, two]}, targetId: 'two', selections: new Map([['two', {start: 1, end: 1}]])}
  // Exercise the same delegated handler as the live hook, with no browser or network.
  const events = {}, button = {dataset: {symbol: '∉'}, matches: () => false}
  const toggle = {}, feedback = {}, panel = {}, keys = {replaceChildren() {}}
  const elements = {'[data-symbol-toggle]': toggle, '.symbol-panel': panel, '[data-symbol-feedback]': feedback, '[data-suggested-keys]': keys, '[data-symbol-suggestions]': {}}
  const fields = {querySelectorAll: () => [one, two], addEventListener() {}, removeEventListener() {}, contains: f => [one,two].includes(f)}
  const oldDocument = globalThis.document
  globalThis.document = {getElementById: () => fields, addEventListener() {}, removeEventListener() {}}
  const liveHook = {...SymbolPalette, el: {dataset: {fields: 'fields', suggestions: '[]'}, querySelector: s => elements[s], addEventListener: (name, fn) => {events[name] = fn}, removeEventListener() {}, parentElement: {addEventListener() {}, removeEventListener() {}}}}
  try {
    liveHook.mounted()
    liveHook.targetId = hook.targetId
    liveHook.selections = hook.selections
    events.click({target: {closest: () => button}})
    assert.equal(one.value, 'AB')
    assert.equal(two.value, 'C∉D')
    assert.equal(two.events.length, 1)
    assert.equal(feedback.textContent, '∉ inséré')
    button.dataset.symbol = 'ñ'
    events.click({target: {closest: () => button}})
    assert.equal(two.value, 'C∉ñD')
    liveHook.destroyed()
  } finally {globalThis.document = oldDocument}
})

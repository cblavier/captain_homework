import {test} from 'node:test'
import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'

const source = readFileSync(new URL('../../assets/js/paris_date.js', import.meta.url), 'utf8')
const {formatParisDate, ParisDate} = await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`)

test('Paris dates handle winter, summer and daylight saving transitions without a timezone suffix', () => {
  for (const [utc, expected] of [
    ['2026-11-11T17:06:00Z', '11/11/2026 à 18:06'],
    ['2026-07-11T17:06:00Z', '11/07/2026 à 19:06'],
    ['2026-03-29T00:30:00Z', '29/03/2026 à 01:30'],
    ['2026-03-29T01:30:00Z', '29/03/2026 à 03:30'],
    ['2026-10-25T00:30:00Z', '25/10/2026 à 02:30'],
    ['2026-10-25T01:30:00Z', '25/10/2026 à 02:30'],
    ['2026-07-11T23:30:00Z', '12/07/2026 à 01:30']
  ]) assert.equal(formatParisDate(utc), expected)
})

test('the hook formats dates on mount and after updates', () => {
  const hook = {...ParisDate, el: {dataset: {date: '2026-11-11T17:06:00Z'}, textContent: ''}}
  hook.mounted()
  assert.equal(hook.el.textContent, '11/11/2026 à 18:06')
  hook.el.dataset.date = '2026-07-11T17:06:00Z'
  hook.updated()
  assert.equal(hook.el.textContent, '11/07/2026 à 19:06')
})

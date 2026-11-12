import {test} from 'node:test'
import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import vm from 'node:vm'

const source = readFileSync(new URL('../../assets/js/pronunciation_recorder.js', import.meta.url), 'utf8')
function setup({permissionError, deferred} = {}) {
  let stopped = 0, timer
  const events = [], uploads = [], callbacks = new Map()
  const button = {addEventListener() {}, removeEventListener() {}}
  const status = {}, label = {}
  const stream = {getTracks: () => [{stop() { stopped++ }}]}
  class Recorder {
    static isTypeSupported(type) { return type === 'audio/mp4' }
    constructor(_stream, {mimeType}) { this.mimeType = mimeType; this.state = 'inactive' }
    start() { this.state = 'recording' }
    stop() {
      this.state = 'inactive'
      this.ondataavailable({data: new Blob(['voice'], {type: this.mimeType})})
      this.onstop()
    }
  }
  const context = {Blob, File, MediaRecorder: Recorder, window: {MediaRecorder: Recorder},
    navigator: {mediaDevices: {async getUserMedia() {
      if (permissionError) throw {name: 'NotAllowedError'}
      if (deferred) await deferred
      return stream
    }}},
    setTimeout(fn) { timer = fn; return 1 }, clearTimeout() { timer = null }
  }
  vm.runInNewContext(source.replace('export const PronunciationRecorder =', 'globalThis.hook ='), context)
  const hook = {...context.hook,
    el: {dataset: {questionId: 'q1', uploadName: 'recording-exam-q1', disabled: 'false'}, querySelector: s => s === '[data-record]' ? button : s === '[data-record-label]' ? label : status},
    pushEvent(name, data) { events.push({name, ...data}) },
    handleEvent(name, fn) { callbacks.set(name, fn) },
    upload(name, files) { uploads.push({name, files}) }
  }
  hook.mounted()
  return {hook, events, uploads, button, status, label, callbacks, stop: () => timer(), stopped: () => stopped}
}

test('MP4 browser recordings auto-stop, upload, and wait for server confirmation', async () => {
  const env = setup()
  await env.hook.toggle()
  assert.equal(env.events[0].active, true)
  env.stop()
  assert.equal(env.stopped(), 1)
  assert.equal(env.uploads[0].name, 'recording-exam-q1')
  assert.equal(env.uploads[0].files[0].name, 'prononciation.mp4')
  assert.equal(env.button.disabled, true)
  env.callbacks.get('recording:saved')({id: 'q1', error: null})
  assert.equal(env.button.disabled, false)
  assert.equal(env.status.textContent, '')
  assert.equal(env.label.textContent, 'Recommencer')
})

test('microphone denial releases the submission lock and allows a retry', async () => {
  const env = setup({permissionError: true})
  await env.hook.toggle()
  assert.equal(env.events.at(-1).active, false)
  assert.equal(env.button.disabled, false)
  assert.equal(env.uploads.length, 0)
  assert.match(env.status.textContent, /Autorise le microphone/)
})

test('leaving during permission request closes the microphone and never uploads', async () => {
  let grant
  const deferred = new Promise(resolve => { grant = resolve })
  const env = setup({deferred})
  const pending = env.hook.toggle()
  env.hook.destroyed()
  grant()
  await pending
  assert.equal(env.stopped(), 1)
  assert.equal(env.uploads.length, 0)
  assert.equal(env.events.at(-1).active, false)
})

test('server save errors clear local status because the form already displays them', async () => {
  const env = setup()
  await env.hook.toggle()
  env.stop()
  env.callbacks.get('recording:saved')({id: 'q1', error: 'La copie a changé.'})
  assert.equal(env.status.textContent, '')
  assert.equal(env.button.disabled, false)
  assert.equal(env.label.textContent, 'Recommencer')
})

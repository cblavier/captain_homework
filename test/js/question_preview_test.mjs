import {test} from 'node:test'
import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import vm from 'node:vm'
const source = readFileSync(new URL('../../assets/js/question_preview.js', import.meta.url), 'utf8')
function setup(getMedia) {
  const callbacks = new Map(), revoked = [], tracks = [{stopped: false, stop() {this.stopped = true}}]
  const stream = {getTracks: () => tracks}
  const button = {addEventListener: (event, fn) => callbacks.set(event, fn)}
  const status = {}, player = {hidden: true}
  class Recorder {
    constructor() {this.state = 'inactive'; this.mimeType = 'audio/webm'}
    start() {this.state = 'recording'}
    stop() {this.state = 'inactive'; this.ondataavailable({data: new Blob(['voice'])}); this.onstop()}
  }
  const context = vm.createContext({navigator: {mediaDevices: {getUserMedia: getMedia || (() => Promise.resolve(stream))}}, window: {MediaRecorder: Recorder}, MediaRecorder: Recorder, Blob, URL: {createObjectURL: () => 'blob:preview', revokeObjectURL: url => revoked.push(url)}})
  vm.runInContext(source.replaceAll('export const ', 'globalThis.'), context)
  const hook = {...context.QuestionPreviewRecorder, el: {querySelector: selector => ({'[data-record]': button, '[data-status]': status, '[data-playback]': player}[selector])}}
  hook.mounted()
  return {hook, click: () => callbacks.get('click')(), button, status, player, stream, tracks, revoked}
}
test('recorded audio stays local and its tracks and object URL are cleaned up', async () => {
  const env = setup()
  await env.click()
  assert.equal(env.hook.recorder.state, 'recording')
  await env.click()
  assert.equal(env.player.src, 'blob:preview')
  assert.equal(env.player.hidden, false)
  assert.ok(env.tracks.every(t => t.stopped))
  env.hook.destroyed()
  assert.deepEqual(env.revoked, ['blob:preview'])
})
test('leaving the preview while permission is pending closes the late stream', async () => {
  let resolve
  const env = setup(() => new Promise(r => {resolve = r}))
  const recording = env.click()
  env.hook.destroyed()
  resolve(env.stream)
  await recording
  assert.ok(env.tracks.every(t => t.stopped))
  assert.equal(env.hook.recorder, undefined)
})
test('denied microphone permission provides feedback and allows retry', async () => {
  const env = setup(() => Promise.reject({name: 'NotAllowedError'}))
  await env.click()
  assert.match(env.status.textContent, /Autorise le microphone/)
  assert.equal(env.button.disabled, false)
})

function photoSetup() {
  const nodes = {}, revoked = []
  for (const selector of ['input', '[data-photo-remove]', '[data-photo-error]', '[data-photo]', '[data-photo-empty]', '[data-photo-preview]', '[data-photo-label]']) {
    nodes[selector] = {handlers: {}, addEventListener(name, fn) {this.handlers[name] = fn}, removeAttribute(name) {delete this[name]}}
  }
  const context = vm.createContext({URL: {createObjectURL: file => `blob:${file.name}`, revokeObjectURL: url => revoked.push(url)}})
  vm.runInContext(source.replaceAll('export const ', 'globalThis.'), context)
  const hook = {...context.QuestionPreviewPhoto, el: {addEventListener() {}, removeEventListener() {}, querySelector: selector => nodes[selector]}}
  hook.mounted()
  const choose = file => {nodes.input.files = [file]; nodes.input.handlers.change()}
  return {nodes, hook, revoked, choose}
}
test('photo preview replaces and removes images and releases object URLs', () => {
  const {nodes, hook, revoked, choose} = photoSetup()
  choose({name: 'first.png', type: 'image/png', size: 100})
  assert.equal(nodes['[data-photo-preview]'].hidden, false)
  assert.equal(nodes['[data-photo-label]'].textContent, 'Remplacer la photo')
  choose({name: 'second.png', type: 'image/png', size: 100})
  assert.deepEqual(revoked, ['blob:first.png'])
  nodes['[data-photo-remove]'].handlers.click()
  assert.equal(nodes['[data-photo-preview]'].hidden, true)
  assert.equal(nodes['[data-photo]'].src, undefined)
  assert.deepEqual(revoked, ['blob:first.png', 'blob:second.png'])
  hook.destroyed()
})
test('invalid or oversized photos preserve the previously selected preview', () => {
  const {nodes, choose} = photoSetup()
  choose({name: 'valid.png', type: 'image/png', size: 100})
  for (const file of [{name: 'document.pdf', type: 'application/pdf', size: 10}, {name: 'large.png', type: 'image/png', size: 12000001}]) {
    choose(file)
    assert.equal(nodes['[data-photo-error]'].hidden, false)
    assert.equal(nodes['[data-photo]'].src, 'blob:valid.png')
  }
})

test('webcam photos use the local preview without uploading', () => {
  const {nodes, hook} = photoSetup()
  hook.onWebcamPhoto({detail: {file: {name: 'webcam.jpg', type: 'image/jpeg', size: 100}}})
  assert.equal(nodes['[data-photo]'].src, 'blob:webcam.jpg')
  assert.equal(nodes['[data-photo-preview]'].hidden, false)
  nodes['[data-photo-remove]'].handlers.click()
  assert.equal(nodes['[data-photo-preview]'].hidden, true)
})

import {test} from 'node:test'
import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import vm from 'node:vm'
const source = readFileSync(new URL('../../assets/js/webcam_capture.js', import.meta.url), 'utf8')
function setup(getMedia) {
  const nodes = {}, revoked = [], uploads = []
  for (const name of ['open', 'close', 'video', 'preview', 'status', 'shoot', 'retry', 'use', 'dialog']) {
    nodes[name] = {handlers: {}, addEventListener(event, callback) {this.handlers[event] = callback}, removeAttribute(key) {delete this[key]}, play: async () => {}, videoWidth: 1280, videoHeight: 720}
  }
  nodes.dialog.showModal = () => {}
  nodes.dialog.close = () => nodes.dialog.handlers.close()
  const track = {stopped: false, stop() {this.stopped = true}}
  const stream = {getTracks: () => [track]}
  const context = vm.createContext({navigator: {mediaDevices: {getUserMedia: getMedia || (async () => stream)}}, document: {createElement: () => ({getContext: () => ({drawImage() {}}), toBlob: callback => callback(new Blob(['photo']))})}, CustomEvent: class {constructor(type, options) {this.type = type; Object.assign(this, options)}}, Blob, File: class {constructor(parts, name, options) {this.name = name; this.type = options.type}}, URL: {createObjectURL: () => 'blob:photo', revokeObjectURL: url => revoked.push(url)}})
  vm.runInContext(source.replace('export const ', 'globalThis.'), context)
  const hook = {...context.WebcamCapture, el: {dataset: {uploadName: 'drawing-42-q1'}, querySelector: selector => nodes[selector === 'dialog' ? 'dialog' : selector.slice(13, -1)]}, upload: (...args) => uploads.push(args)}
  hook.mounted()
  return {hook, nodes, track, stream, uploads, revoked}
}
test('capture requires confirmation before upload and releases camera and image', async () => {
  const {hook, nodes, track, uploads, revoked} = setup()
  await hook.startCamera()
  assert.equal(nodes.shoot.disabled, false)
  hook.capture()
  assert.equal(track.stopped, true)
  assert.equal(nodes.preview.src, 'blob:photo')
  assert.equal(uploads.length, 0)
  nodes.use.handlers.click()
  assert.equal(uploads[0][0], 'drawing-42-q1')
  assert.equal(uploads[0][1][0].type, 'image/jpeg')
  assert.deepEqual(revoked, ['blob:photo'])
})
test('closing while permission is pending stops the late camera stream', async () => {
  let resolve
  const env = setup(() => new Promise(r => {resolve = r}))
  const opening = env.hook.startCamera()
  env.nodes.dialog.close()
  resolve(env.stream)
  await opening
  assert.equal(env.track.stopped, true)
  assert.equal(env.nodes.video.srcObject, null)
})
test('permission denial explains the fallback and permits retry', async () => {
  const {hook, nodes} = setup(async () => {throw {name: 'NotAllowedError'}})
  await hook.startCamera()
  assert.match(nodes.status.textContent, /Accès à la caméra refusé/)
  assert.equal(nodes.retry.hidden, false)
  assert.equal(nodes.shoot.disabled, true)
})

test('settings preview receives a local photo event instead of an upload', async () => {
  const {hook, nodes, uploads} = setup()
  delete hook.el.dataset.uploadName
  let event
  hook.el.dispatchEvent = value => {event = value}
  await hook.startCamera()
  hook.capture()
  nodes.use.handlers.click()
  assert.equal(uploads.length, 0)
  assert.equal(event.type, 'webcam:photo')
  assert.equal(event.bubbles, true)
  assert.equal(event.detail.file.name, 'reponse-webcam.jpg')
})

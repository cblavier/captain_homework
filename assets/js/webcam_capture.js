export const WebcamCapture = {
  mounted() {
    this.active = true
    this.generation = 0
    const find = name => this.el.querySelector(`[data-camera-${name}]`)
    this.dialog = this.el.querySelector('dialog')
    this.video = find('video')
    this.preview = find('preview')
    this.status = find('status')
    this.shoot = find('shoot')
    this.retry = find('retry')
    this.use = find('use')
    find('open').addEventListener('click', () => { this.dialog.showModal(); this.startCamera() })
    find('close').addEventListener('click', () => this.dialog.close())
    this.dialog.addEventListener('close', () => this.cleanup())
    // Keep Escape inside this dialog, including when the transcription modal is open.
    this.dialog.addEventListener('keydown', event => event.stopPropagation())
    this.retry.addEventListener('click', () => this.startCamera())
    this.shoot.addEventListener('click', () => this.capture())
    this.use.addEventListener('click', () => {
      if (!this.file) return
      if (this.el.dataset.uploadName) {
        this.upload(this.el.dataset.uploadName, [this.file])
      } else {
        this.el.dispatchEvent(new CustomEvent('webcam:photo', {bubbles: true, detail: {file: this.file}}))
      }
      this.dialog.close()
    })
  },
  stopCamera() {
    this.stream?.getTracks().forEach(track => track.stop())
    this.stream = null
    this.video.srcObject = null
  },
  cleanup() {
    this.generation++
    this.stopCamera()
    if (this.url) URL.revokeObjectURL(this.url)
    this.url = null
    this.file = null
    this.preview.removeAttribute('src')
  },
  async startCamera() {
    this.cleanup()
    const generation = this.generation
    this.preview.hidden = true
    this.video.hidden = false
    this.retry.hidden = true
    this.use.hidden = true
    this.shoot.hidden = false
    this.shoot.disabled = true
    this.status.textContent = 'Autorise la caméra pour afficher l’aperçu…'
    try {
      if (!navigator.mediaDevices?.getUserMedia) throw new Error('unsupported')
      const stream = await navigator.mediaDevices.getUserMedia({audio: false, video: {facingMode: {ideal: 'environment'}, width: {ideal: 1920}, height: {ideal: 1080}}})
      if (!this.active || generation !== this.generation) { stream.getTracks().forEach(track => track.stop()); return }
      this.stream = stream
      this.video.srcObject = stream
      await this.video.play()
      if (!this.active || generation !== this.generation) return
      this.shoot.disabled = false
      this.status.textContent = 'Tout le contenu visible sera conservé. Évite les reflets et garde la feuille immobile.'
    } catch (error) {
      if (!this.active || generation !== this.generation) return
      this.stopCamera()
      this.status.textContent = error.name === 'NotAllowedError'
        ? 'Accès à la caméra refusé. Autorise-le dans ton navigateur, ou ferme cet aperçu pour choisir un fichier.'
        : 'Caméra indisponible. Vérifie qu’elle est connectée et libre. La webcam nécessite HTTPS ou localhost ; tu peux aussi choisir un fichier.'
      this.retry.hidden = false
    }
  },
  capture() {
    if (!this.video.videoWidth || !this.video.videoHeight) return
    const generation = this.generation
    const canvas = document.createElement('canvas')
    canvas.width = this.video.videoWidth
    canvas.height = this.video.videoHeight
    canvas.getContext('2d').drawImage(this.video, 0, 0)
    this.shoot.disabled = true
    canvas.toBlob(blob => {
      if (!this.active || generation !== this.generation) return
      if (!blob || blob.size > 12000000) {
        this.status.textContent = 'La photo n’a pas pu être créée. Réessaie.'
        this.shoot.disabled = false
        return
      }
      this.file = new File([blob], 'reponse-webcam.jpg', {type: 'image/jpeg'})
      this.url = URL.createObjectURL(blob)
      this.preview.src = this.url
      this.preview.hidden = false
      this.video.hidden = true
      this.shoot.hidden = true
      this.retry.hidden = false
      this.use.hidden = false
      this.status.textContent = 'Vérifie que toute ta réponse est lisible avant d’utiliser cette photo.'
      this.stopCamera()
    }, 'image/jpeg', 0.92)
  },
  destroyed() { this.active = false; this.cleanup(); this.dialog.close() }
}

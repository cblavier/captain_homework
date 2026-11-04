export const QuestionPreviewRecorder = {
  mounted() {
    this.active = true
    this.button = this.el.querySelector('[data-record]')
    this.status = this.el.querySelector('[data-status]')
    this.player = this.el.querySelector('[data-playback]')
    this.button.addEventListener('click', async () => {
      if (this.recorder?.state === 'recording') { this.recorder.stop(); return }
      this.button.disabled = true
      try {
        if (!navigator.mediaDevices?.getUserMedia || !window.MediaRecorder) throw new Error('unsupported')
        const stream = await navigator.mediaDevices.getUserMedia({audio: true})
        if (!this.active) { stream.getTracks().forEach(t => t.stop()); return }
        this.stream = stream
        this.recorder = new MediaRecorder(stream)
        const chunks = []
        this.recorder.ondataavailable = e => { if (e.data.size) chunks.push(e.data) }
        this.recorder.onstop = () => {
          stream.getTracks().forEach(t => t.stop())
          if (!this.active) return
          if (this.url) URL.revokeObjectURL(this.url)
          this.url = URL.createObjectURL(new Blob(chunks, {type: this.recorder.mimeType}))
          this.player.src = this.url
          this.player.hidden = false
          this.status.textContent = 'Enregistrement prêt à écouter'
          this.button.textContent = 'Recommencer'
        }
        this.recorder.start()
        this.status.textContent = 'Enregistrement en cours'
        this.button.textContent = 'Arrêter'
      } catch (error) {
        this.stream?.getTracks().forEach(t => t.stop())
        if (this.active) this.status.textContent = error.name === 'NotAllowedError' ? 'Autorise le microphone pour essayer cet aperçu.' : 'Le microphone nécessite HTTPS ou localhost et un navigateur compatible.'
      } finally { if (this.active) this.button.disabled = false }
    })
  },
  destroyed() {
    this.active = false
    if (this.recorder?.state === 'recording') this.recorder.stop()
    this.stream?.getTracks().forEach(t => t.stop())
    if (this.url) URL.revokeObjectURL(this.url)
  }
}
export const QuestionPreviewPhoto = {
  mounted() {
    this.input = this.el.querySelector('input')
    this.remove = this.el.querySelector('[data-photo-remove]')
    this.onWebcamPhoto = event => this.selectPhoto(event.detail.file)
    this.el.addEventListener('webcam:photo', this.onWebcamPhoto)
    this.input.addEventListener('change', () => this.selectPhoto(this.input.files[0]))
    this.remove.addEventListener('click', () => {
      if (this.url) URL.revokeObjectURL(this.url)
      this.url = null
      this.input.value = ''
      this.el.querySelector('[data-photo]').removeAttribute('src')
      this.el.querySelector('[data-photo-error]').hidden = true
      this.showPhoto(false)
    })
  },
  selectPhoto(file) {
    if (!file) return
    const error = this.el.querySelector('[data-photo-error]')
    if (!['image/jpeg', 'image/png', 'image/webp'].includes(file.type) || file.size > 12000000) {
      error.textContent = 'Choisis une image JPEG, PNG ou WebP de moins de 12 Mo.'
      error.hidden = false
      this.input.value = ''
      return
    }
    error.hidden = true
    if (this.url) URL.revokeObjectURL(this.url)
    this.url = URL.createObjectURL(file)
    this.el.querySelector('[data-photo]').src = this.url
    const filename = this.el.querySelector('[data-photo-name]')
    if (filename) filename.textContent = file.name
    this.showPhoto(true)
  },
  showPhoto(present) {
    this.el.querySelector('[data-photo-empty]').hidden = present
    this.el.querySelector('[data-photo-preview]').hidden = !present
    this.remove.hidden = !present
    this.el.querySelector('[data-photo-label]').textContent = present ? 'Remplacer la photo' : 'Prendre ou choisir une photo'
  },
  destroyed() {
    this.el.removeEventListener('webcam:photo', this.onWebcamPhoto)
    if (this.url) URL.revokeObjectURL(this.url)
  }
}

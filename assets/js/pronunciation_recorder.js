export const PronunciationRecorder = {
  mounted() {
    this.active = true
    this.button = this.el.querySelector('[data-record]')
    this.label = this.el.querySelector('[data-record-label]')
    this.status = this.el.querySelector('[data-status]')
    this.onClick = () => this.toggle()
    this.button.addEventListener('click', this.onClick)
    this.handleEvent('recording:saved', ({id}) => {
      if (id !== this.el.dataset.questionId) return
      this.busy = false
      this.status.textContent = ''
      this.label.textContent = 'Recommencer'
      this.updated()
    })
  },
  updated() {
    this.button.disabled = this.busy || this.el.dataset.disabled === 'true'
  },
  state(active) {
    this.pushEvent('recording_state', {id: this.el.dataset.questionId, active})
  },
  async toggle() {
    if (this.recorder?.state === 'recording') {
      this.recorder.stop()
      return
    }
    if (this.busy || this.el.dataset.disabled === 'true') return
    this.busy = true
    this.updated()
    this.state(true)
    try {
      if (!navigator.mediaDevices?.getUserMedia || !window.MediaRecorder) throw new Error('unsupported')
      const stream = await navigator.mediaDevices.getUserMedia({audio: true})
      if (!this.active || this.el.dataset.disabled === 'true') {
        stream.getTracks().forEach(track => track.stop())
        this.state(false)
        return
      }
      this.stream = stream
      const mimeType = ['audio/webm;codecs=opus', 'audio/mp4', 'audio/ogg;codecs=opus'].find(type => MediaRecorder.isTypeSupported(type))
      this.recorder = new MediaRecorder(stream, mimeType ? {mimeType} : {})
      const chunks = []
      this.recorder.ondataavailable = event => { if (event.data.size) chunks.push(event.data) }
      this.recorder.onerror = () => this.fail('L’enregistrement a échoué. Réessaie.')
      this.recorder.onstop = () => {
        clearTimeout(this.timer)
        stream.getTracks().forEach(track => track.stop())
        if (!this.active || this.failed) return
        const type = this.recorder.mimeType || mimeType || 'audio/webm'
        const blob = new Blob(chunks, {type})
        if (!blob.size || blob.size > 5000000) { this.fail('Enregistrement vide ou trop volumineux. Réessaie.'); return }
        const ext = type.includes('mp4') ? 'mp4' : type.includes('ogg') ? 'ogg' : 'webm'
        this.busy = true
        this.updated()
        this.status.textContent = 'Envoi de l’enregistrement…'
        this.upload(this.el.dataset.uploadName, [new File([blob], `prononciation.${ext}`, {type})])
      }
      this.failed = false
      this.recorder.start()
      this.busy = false
      this.label.textContent = 'Arrêter l’enregistrement'
      this.status.textContent = 'Enregistrement en cours — 60 secondes maximum.'
      this.updated()
      this.timer = setTimeout(() => {
        if (this.recorder?.state === 'recording') this.recorder.stop()
      }, 60000)
    } catch (error) {
      this.fail(error.name === 'NotAllowedError' ? 'Autorise le microphone pour enregistrer ta réponse.' : 'Le microphone nécessite HTTPS ou localhost et un navigateur compatible.')
    }
  },
  fail(message) {
    this.failed = true
    clearTimeout(this.timer)
    this.stream?.getTracks().forEach(track => track.stop())
    this.busy = false
    this.state(false)
    if (this.active) {
      this.status.textContent = message
      this.label.textContent = 'Réessayer l’enregistrement'
      this.updated()
    }
  },
  disconnected() {
    this.fail('Connexion interrompue. Réenregistre ta réponse après reconnexion.')
  },
  reconnected() {
    this.busy = false
    this.state(false)
    this.updated()
  },
  destroyed() {
    this.active = false
    clearTimeout(this.timer)
    if (this.recorder?.state === 'recording') this.recorder.stop()
    this.stream?.getTracks().forEach(track => track.stop())
    this.button.removeEventListener('click', this.onClick)
    this.state(false)
  }
}

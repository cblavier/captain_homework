export const PageDrag = {
  mounted() {
    this.start = event => {
      if (!matchMedia('(pointer: fine)').matches || event.target.closest('button')) {
        event.preventDefault()
        return
      }
      const grid = this.el.closest('.pages-grid')
      if (!grid) return
      const card = this.el.closest('.learning-card')
      event.dataTransfer.effectAllowed = 'move'
      event.dataTransfer.setData('text/plain', this.el.dataset.pageId)
      event.dataTransfer.setDragImage(card, 20, 20)
      const marker = document.createElement('div')
      marker.className = 'page-drop-marker'
      marker.hidden = true
      document.body.append(marker)
      let target = null
      let valid = false
      this.over = e => {
        valid = grid.contains(e.target)
        marker.hidden = !valid
        if (!valid) return
        e.preventDefault()
        e.dataTransfer.dropEffect = 'move'
        const cards = [...grid.querySelectorAll(':scope > .learning-card')]
        const hit = cards.find(c => {
          const r = c.getBoundingClientRect()
          return e.clientY <= r.bottom && (e.clientY < r.top || e.clientX < r.right)
        }) || cards.at(-1)
        const r = hit.getBoundingClientRect()
        const before = e.clientY < r.top || e.clientX < r.left + r.width / 2
        const next = before ? hit : cards[cards.indexOf(hit) + 1]
        target = next?.querySelector('[data-page-id]')?.dataset.pageId || null
        marker.style.left = `${(before ? r.left : r.right) - 3}px`
        marker.style.top = `${r.top}px`
        marker.style.height = `${r.height}px`
      }
      this.drop = e => {
        if (valid && grid.contains(e.target)) {
          e.preventDefault()
          this.pushEvent('reorder_page', {id: this.el.dataset.pageId, before_id: target})
        }
        this.finish()
      }
      this.finish = () => {
        marker.remove()
        document.removeEventListener('dragover', this.over)
        document.removeEventListener('drop', this.drop)
        document.removeEventListener('dragend', this.finish)
        this.finish = null
      }
      document.addEventListener('dragover', this.over)
      document.addEventListener('drop', this.drop)
      document.addEventListener('dragend', this.finish)
    }
    this.el.addEventListener('dragstart', this.start)
  },
  destroyed() {
    this.finish?.()
    this.el.removeEventListener('dragstart', this.start)
  }
}

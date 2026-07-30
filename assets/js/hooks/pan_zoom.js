import { BoardView } from "../lib/board.js"

export const PanZoom = {
  mounted() {
    const surface = this.el
    // start each trip at the default view
    BoardView.scale = 1
    BoardView.panX = 0
    BoardView.panY = 0
    BoardView.apply()
    let two = null
    let one = null // single-finger pan state
    const rect = () => surface.getBoundingClientRect()

    // Interactive bits whose own gesture must win over panning. A single-finger
    // pan may begin anywhere else — empty board OR the blank body of a meal/bill
    // card — but never on one of these.
    const NO_PAN =
      "button, a, input, textarea, select, label, form," +
      ".drag-handle, .field-overlay, .field-label, .traveller-token," +
      "[phx-click], [phx-hook='LongPress']"

    const twoFinger = (e) => {
      const [a, b] = [e.touches[0], e.touches[1]]
      return {
        dist: Math.hypot(b.clientX - a.clientX, b.clientY - a.clientY),
        midX: (a.clientX + b.clientX) / 2,
        midY: (a.clientY + b.clientY) / 2
      }
    }

    surface.addEventListener("touchstart", (e) => {
      if (e.touches.length === 2) {
        two = twoFinger(e)
        one = null
        window.__sianoPanning = true
      } else if (e.touches.length === 1) {
        // Single-finger pan — starts on empty board or on the blank body of a
        // card, but never on an interactive control (its action has priority).
        if (window.__sianoDragging) return
        if (e.target.closest(NO_PAN)) return
        const t = e.touches[0]
        // leave the thin screen-edge zones for the drawer edge-swipe gestures
        if (t.clientX <= 28 || t.clientX >= window.innerWidth - 28) return
        one = { x: t.clientX, y: t.clientY }
      }
    }, { passive: true })

    surface.addEventListener("touchmove", (e) => {
      if (e.touches.length === 2 && two) {
        e.preventDefault()
        const cur = twoFinger(e)
        const r = rect()
        // pinch to zoom around the fingers' midpoint...
        if (two.dist > 0) BoardView.zoomAt(cur.midX - r.left, cur.midY - r.top, cur.dist / two.dist)
        // ...and pan as the midpoint moves
        BoardView.panX += cur.midX - two.midX
        BoardView.panY += cur.midY - two.midY
        BoardView.apply()
        two = cur
      } else if (e.touches.length === 1 && one) {
        e.preventDefault()
        const t = e.touches[0]
        BoardView.panX += t.clientX - one.x
        BoardView.panY += t.clientY - one.y
        one.x = t.clientX
        one.y = t.clientY
        // treat an active board pan as a "drag" so drawer edge-swipes stay quiet
        window.__sianoDragging = true
        BoardView.apply()
      }
    }, { passive: false })

    const endTouch = (e) => {
      if (e.touches.length < 2) {
        two = null
        window.__sianoPanning = false
      }
      if (e.touches.length === 1) {
        // dropped from two fingers to one -> continue as a single-finger pan
        const t = e.touches[0]
        one = { x: t.clientX, y: t.clientY }
      } else if (e.touches.length === 0) {
        one = null
        setTimeout(() => { window.__sianoDragging = false }, 0)
      }
    }
    surface.addEventListener("touchend", endTouch)
    surface.addEventListener("touchcancel", endTouch)

    // Desktop / trackpad: wheel to pan, ctrl+wheel (pinch) to zoom.
    surface.addEventListener("wheel", (e) => {
      e.preventDefault()
      const r = rect()
      if (e.ctrlKey) {
        BoardView.zoomAt(e.clientX - r.left, e.clientY - r.top, Math.exp(-e.deltaY * 0.01))
      } else {
        BoardView.panX -= e.deltaX
        BoardView.panY -= e.deltaY
        BoardView.apply()
      }
    }, { passive: false })

    // Keep the same board point centred when the viewport resizes (mainly a
    // portrait<->landscape rotation): work out which canvas point sits at the
    // centre now, then shift the pan so that point is centred at the new size.
    // So whatever the user was looking at stays in front of them after rotating.
    this.lastW = surface.clientWidth
    this.lastH = surface.clientHeight
    this.ro = new ResizeObserver(() => {
      const w = surface.clientWidth
      const h = surface.clientHeight
      if (!w || !h) return
      const ow = this.lastW
      const oh = this.lastH
      if (ow && oh && (ow !== w || oh !== h)) {
        const s = BoardView.scale
        const cx = (ow / 2 - BoardView.panX) / s
        const cy = (oh / 2 - BoardView.panY) / s
        BoardView.panX = w / 2 - cx * s
        BoardView.panY = h / 2 - cy * s
        BoardView.apply()
      }
      this.lastW = w
      this.lastH = h
    })
    this.ro.observe(surface)
  },
  updated() {
    BoardView.apply()
  },
  destroyed() {
    if (this.ro) this.ro.disconnect()
  }
}


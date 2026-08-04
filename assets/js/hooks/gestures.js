// Edge-swipe gestures for the two drawers, mirroring the buttons:
//   • swipe in from the LEFT edge  -> open Bills   (left drawer)
//   • swipe in from the RIGHT edge -> open Settings (right drawer)
//   • while Bills is open,   swipe left  -> close it
//   • while Settings is open, swipe right -> close it
// It toggles exactly the same classes the phx-click handlers use, so the two
// stay in sync. Touch-only, so it never interferes with mouse use on desktop.
//
// Dragging takes priority over swiping, but only when a drag is *actually*
// happening — not merely because the touch landed on something draggable. Meal
// cards, bill photos and their recognised-price fields all live inside the
// board, but the only things that start a drag are the card's .drag-handle, a
// traveller token, and a field label — and each of those flips
// window.__sianoDragging the moment it truly begins moving. So instead of
// statically vetoing any swipe that starts over a card/field (which used to
// swallow legitimate edge-swipes across a card body or a bill photo), we let
// that runtime flag be the sole arbiter: a real drag cancels the swipe, while a
// pure horizontal edge-swipe with no drag opens the drawer as expected.
export const Gestures = {
  mounted() {
    const EDGE = 28 // px from a screen border where an "open" swipe may start
    const THRESH = 60 // px of horizontal travel required to count as a swipe
    const RATIO = 1.7 // swipe must be this much more horizontal than vertical
    const MAX_DY = 55 // and never wander too far vertically (that's a drag/scroll)

    // tracking state for the single active touch
    let x0 = null, y0 = null, invalid = false

    const el = (id) => document.getElementById(id)
    // Drawer open/closed state is server-tracked; read it from the rendered
    // class, and drive it by pushing events (so it survives re-renders).
    const billsOpen = () => el("bills") && !el("bills").classList.contains("-translate-x-full")
    const menuOpen = () => el("menu") && !el("menu").classList.contains("translate-x-full")
    const openBills = () => this.pushEvent("open_drawer", { which: "bills" })
    const openMenu = () => this.pushEvent("open_drawer", { which: "menu" })
    const closeBills = () => this.pushEvent("close_drawer", {})
    const closeMenu = () => this.pushEvent("close_drawer", {})

    this.el.addEventListener("touchstart", (e) => {
      // ignore multi-touch; a single-finger press anywhere is a candidate swipe.
      // Whether it turns out to be a drag instead is decided later by
      // window.__sianoDragging (see touchmove/touchend), not by what sits under
      // the finger — so a swipe over a card body or bill photo still counts.
      if (e.touches.length !== 1) { invalid = true; x0 = null; return }
      const t = e.touches[0]
      x0 = t.clientX
      y0 = t.clientY
      invalid = false
    }, { passive: true })

    this.el.addEventListener("touchmove", (e) => {
      // if a drag kicks in mid-gesture, abandon any swipe interpretation
      if (x0 !== null && window.__sianoDragging) invalid = true
    }, { passive: true })

    this.el.addEventListener("touchend", (e) => {
      const startX = x0
      // A drag that actually kicked in (flag set by the traveller / meal-card /
      // field-label hooks, cleared on the next tick so we still see it here)
      // wins over the swipe; anything else is a real drawer gesture.
      const bad = invalid || window.__sianoDragging
      x0 = null
      invalid = false
      if (startX === null || bad) return

      const t = e.changedTouches[0]
      const dx = t.clientX - startX
      const dy = t.clientY - (y0 ?? t.clientY)

      // a real swipe: long enough, mostly horizontal, and not drifting vertically
      if (Math.abs(dx) < THRESH) return
      if (Math.abs(dy) > MAX_DY) return
      if (Math.abs(dx) < RATIO * Math.abs(dy)) return

      if (billsOpen()) {
        if (dx < 0) closeBills() // swipe left closes the left drawer
      } else if (menuOpen()) {
        if (dx > 0) closeMenu() // swipe right closes the right drawer
      } else if (dx > 0 && startX <= EDGE) {
        openBills() // from the very left edge, swipe right
      } else if (dx < 0 && startX >= window.innerWidth - EDGE) {
        openMenu() // from the very right edge, swipe left
      }
    }, { passive: true })
  }
}


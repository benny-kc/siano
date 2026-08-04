import { View } from "../lib/viewstate.js"

// Board-level UI gestures + the triggers for the purely-visual overlays.
//
// This hook lives on the #trip root, so the whole app is inside `this.el`. It
// does two things:
//
//   1. Edge-swipe the two drawers (touch only), mirroring the buttons:
//        • swipe in from the LEFT edge  -> open Bills   (left drawer)
//        • swipe in from the RIGHT edge -> open Settings (right drawer)
//        • while Bills is open,   swipe left  -> close it
//        • while Settings is open, swipe right -> close it
//   2. Handle taps on the overlay triggers (open/close drawer, open/close help,
//      toggle/close the Bills sort popover) via event delegation.
//
// Both go through the shared `View` controller, which flips a data-attribute on
// :root; app.css does the slide/fade with no server round-trip (see
// lib/viewstate.js for why the state lives on :root). The one exception is that
// opening Bills also fires a fire-and-forget `reset_bills_filter` so a fresh
// open always shows every bill — that's server-rendered list state, and it never
// blocks the (already-instant) slide.
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

    // Opening Bills clears any stale per-traveller filter server-side (the list
    // is server-rendered) so reopening always shows everything. Fire-and-forget:
    // the drawer has already slid open via :root, this just re-syncs the list.
    const openBills = () => {
      View.openDrawer("bills")
      this.pushEvent("reset_bills_filter", {})
    }
    const openMenu = () => View.openDrawer("menu")

    // ── Overlay trigger taps (delegated; the whole app is inside this.el) ──────
    this.onClick = (e) => {
      const t = e.target.closest(
        "[data-siano-open],[data-siano-close],[data-siano-help-open]," +
          "[data-siano-help-close],[data-siano-report-open],[data-siano-report-close]," +
          "[data-siano-sortmenu],[data-siano-sortmenu-close]"
      )
      if (!t || !this.el.contains(t)) return
      // Never preventDefault/stopPropagation: sort-option taps also carry a
      // phx-click that must still reach the server to reorder the list.
      if (t.hasAttribute("data-siano-open")) {
        t.getAttribute("data-siano-open") === "bills" ? openBills() : openMenu()
      } else if (t.hasAttribute("data-siano-close")) {
        View.closeDrawer()
      } else if (t.hasAttribute("data-siano-help-open")) {
        View.openHelp()
      } else if (t.hasAttribute("data-siano-help-close")) {
        View.closeHelp()
      } else if (t.hasAttribute("data-siano-report-open")) {
        View.openReport()
      } else if (t.hasAttribute("data-siano-report-close")) {
        View.closeReport()
      } else if (t.hasAttribute("data-siano-sortmenu")) {
        View.toggleSortMenu()
      } else if (t.hasAttribute("data-siano-sortmenu-close")) {
        View.closeSortMenu()
      }
    }
    this.el.addEventListener("click", this.onClick)

    // ── Edge-swipe drawers (touch only) ──────────────────────────────────────
    let x0 = null, y0 = null, invalid = false

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

    this.el.addEventListener("touchmove", () => {
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

      const drawer = View.currentDrawer()
      if (drawer === "bills") {
        if (dx < 0) View.closeDrawer() // swipe left closes the left drawer
      } else if (drawer === "menu") {
        if (dx > 0) View.closeDrawer() // swipe right closes the right drawer
      } else if (dx > 0 && startX <= EDGE) {
        openBills() // from the very left edge, swipe right
      } else if (dx < 0 && startX >= window.innerWidth - EDGE) {
        openMenu() // from the very right edge, swipe left
      }
    }, { passive: true })
  },
  destroyed() {
    if (this.onClick) this.el.removeEventListener("click", this.onClick)
  }
}

import { View } from "../lib/viewstate.js"

// Opening a bill from the Bills drawer.
//
// The rows used to rely purely on the synthesized `click` (a delegated
// `data-siano-close` to slide the drawer shut + a `phx-click="open_meal"`). On a
// phone that first tap was routinely swallowed — a scrollable drawer eats the
// first tap to stop momentum, a just-restored full-screen / re-focused WebView
// consumes the first gesture, and both suppress the *synthesized click* while
// leaving the raw pointer stream intact. So the bill only opened on the *second*
// tap.
//
// Fix: drive the open from the raw `pointerup` (which is not suppressed), and
// keep a `click` path only as a fallback for keyboard/mouse — deduped so a real
// touch never fires it twice. A single tap now always opens the pointed bill.
//
// Delegated on the <ul> so it keeps working as the list re-renders (this board
// is live: any viewer's edit re-renders the rows). Each openable row carries
// `data-bill-open="<meal id>"`; the trailing delete button does not, so it is
// left entirely to the Confirm hook.
export const BillList = {
  mounted() {
    let downOn = null // the row pressed on pointerdown
    let sx = 0, sy = 0, moved = false
    let handled = false // a pointerup just opened a bill; swallow its click

    const openBill = (btn) => {
      const id = btn.getAttribute("data-bill-open")
      if (!id) return
      View.closeDrawer() // slide the drawer shut instantly (client-side)
      this.pushEvent("open_meal", { id }) // bring the bill onto the board
    }

    this.onDown = (e) => {
      downOn = e.target.closest("[data-bill-open]")
      sx = e.clientX
      sy = e.clientY
      moved = false
    }

    // A finger that travels is a scroll/drag, not a tap — disqualify it. (Native
    // scrolling usually fires pointercancel too, handled below; this also covers
    // a slow mouse drag.)
    this.onMove = (e) => {
      if (downOn && (Math.abs(e.clientX - sx) > 10 || Math.abs(e.clientY - sy) > 10)) {
        moved = true
      }
    }

    this.onUp = (e) => {
      const btn = e.target.closest("[data-bill-open]")
      const target = downOn
      downOn = null
      // only a clean tap that started and ended on the same row counts
      if (!btn || btn !== target || moved) return
      handled = true
      setTimeout(() => { handled = false }, 500) // reset for the next tap
      openBill(btn)
    }

    // Fallback for keyboard (Enter/Space) and any pointer whose pointerup we
    // missed. Skipped right after a pointerup already opened the bill, so a real
    // touch never double-fires.
    this.onClick = (e) => {
      if (handled) { handled = false; return }
      const btn = e.target.closest("[data-bill-open]")
      if (btn) openBill(btn)
    }

    this.onCancel = () => { downOn = null }

    this.el.addEventListener("pointerdown", this.onDown)
    this.el.addEventListener("pointermove", this.onMove)
    this.el.addEventListener("pointerup", this.onUp)
    this.el.addEventListener("pointercancel", this.onCancel)
    this.el.addEventListener("click", this.onClick)
  },
  destroyed() {
    this.el.removeEventListener("pointerdown", this.onDown)
    this.el.removeEventListener("pointermove", this.onMove)
    this.el.removeEventListener("pointerup", this.onUp)
    this.el.removeEventListener("pointercancel", this.onCancel)
    this.el.removeEventListener("click", this.onClick)
  }
}

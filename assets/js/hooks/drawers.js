// Make the system Back button (Android back, iOS back-swipe) close an open
// drawer and return to the main screen, instead of leaving the app.
//
// When a drawer opens we push a history entry; the next Back pops it and we
// close the drawer. Closing via the UI pops our entry so history stays tidy.
// A MutationObserver watches the drawers' classes so this works no matter how
// they're opened/closed (buttons or swipe gestures).
const DrawerHistory = {
  drawers: new Set(),
  pushed: false,
  programmatic: false,
  closeFromPop: false,
  pushClose: null, // set by the DrawerWatch hook (uses pushEvent)
  closedClass(el) {
    return el.id === "bills" ? "-translate-x-full" : "translate-x-full"
  },
  anyOpen() {
    for (const el of this.drawers) {
      if (!el.classList.contains(this.closedClass(el))) return true
    }
    return false
  },
  // Reacts to the drawer classes (which the server toggles) to keep the history
  // stack in sync: push an entry when a drawer opens, pop it when one closes.
  sync() {
    const open = this.anyOpen()
    if (open && !this.pushed) {
      history.pushState({ sianoDrawer: true }, "")
      this.pushed = true
    } else if (!open && this.pushed) {
      this.pushed = false
      if (this.closeFromPop) {
        this.closeFromPop = false // Back already popped the entry
      } else {
        this.programmatic = true // UI close -> remove our entry
        history.back()
      }
    }
  }
}

window.addEventListener("popstate", () => {
  if (DrawerHistory.programmatic) {
    DrawerHistory.programmatic = false
    return
  }
  if (DrawerHistory.anyOpen() && DrawerHistory.pushClose) {
    // system Back while a drawer is open -> ask the server to close it
    DrawerHistory.closeFromPop = true
    DrawerHistory.pushClose()
  }
})

export const DrawerWatch = {
  mounted() {
    DrawerHistory.drawers.add(this.el)
    DrawerHistory.pushClose = () => this.pushEvent("close_drawer", {})
    if (!DrawerHistory.anyOpen()) DrawerHistory.pushed = false // resync after nav
    this.obs = new MutationObserver(() => DrawerHistory.sync())
    this.obs.observe(this.el, { attributes: true, attributeFilter: ["class"] })
  },
  destroyed() {
    if (this.obs) this.obs.disconnect()
    DrawerHistory.drawers.delete(this.el)
  }
}

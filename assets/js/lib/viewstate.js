// Client-side, morphdom-proof view state for the purely-visual, *per-viewer*
// toggles: the two drawers (Bills / Settings), the Help overlay and the Bills
// sort-order popover.
//
// These used to round-trip to the server (`@drawer`, `@help`, `@bills_sort_menu`
// assigns) for one reason only: so a LiveView re-render — a new bill arriving,
// someone editing a share — wouldn't reconcile the drawer's open class away and
// snap it shut. That made every open/close wait a full server hop, which is very
// visible on a phone over cellular. But whether *this* viewer has a drawer open
// is nobody else's business, so there is nothing to share and nothing to wait
// for.
//
// So we do exactly what the pan/zoom transform already does (see lib/board.js):
// keep the state as data-attributes on :root. morphdom never touches the <html>
// element, so re-renders leave whatever the user opened exactly as they left it,
// and the matching CSS in app.css slides/fades instantly with no server hop.
//
//   data-siano-drawer   = "bills" | "menu" (absent = both closed)
//   data-siano-help     = present when the help overlay is open
//   data-siano-report   = present when the report & backup overlay is open
//   data-siano-sortmenu = present when the Bills sort popover is open
//
// The server still owns everything *shared*: the bills list, its sort order and
// its per-traveller filter are all server-rendered as before — only the visual
// open/closed state moved to the client.

const root = document.documentElement

// ── Android-/browser-Back integration ──────────────────────────────────────
// Mirrors the old DrawerWatch behaviour: pushing a history entry when an overlay
// opens so the system Back button closes it (instead of leaving the app) rather
// than navigating away. Driven off View's own state now, so there is no longer a
// MutationObserver watching drawer classes.
const History = {
  pushed: false,
  programmatic: false, // we called history.back() ourselves (UI close)
  closeFromPop: false, // Back popped our entry (system close)
  // The Bills sort popover is a tiny in-drawer menu, not a full-screen overlay,
  // so — as before — it does not participate in Back handling.
  anyOpen() {
    return !!View.currentDrawer() || View.helpOpen() || View.reportOpen()
  },
  sync() {
    const open = this.anyOpen()
    if (open && !this.pushed) {
      history.pushState({ sianoOverlay: true }, "")
      this.pushed = true
    } else if (!open && this.pushed) {
      this.pushed = false
      if (this.closeFromPop) {
        this.closeFromPop = false // Back already removed the entry
      } else {
        this.programmatic = true // UI close -> drop our entry
        history.back()
      }
    }
  }
}

export const View = {
  // ── Drawers ───────────────────────────────────────────────────────────────
  currentDrawer() {
    return root.getAttribute("data-siano-drawer") || null
  },
  openDrawer(which) {
    if (which !== "bills" && which !== "menu") return
    root.setAttribute("data-siano-drawer", which)
    this.closeSortMenu() // a fresh open never keeps a stale popover showing
    History.sync()
  },
  closeDrawer() {
    root.removeAttribute("data-siano-drawer")
    this.closeSortMenu()
    History.sync()
  },

  // ── Help overlay ────────────────────────────────────────────────────────────
  helpOpen() {
    return root.hasAttribute("data-siano-help")
  },
  openHelp() {
    root.setAttribute("data-siano-help", "")
    History.sync()
  },
  closeHelp() {
    root.removeAttribute("data-siano-help")
    History.sync()
  },

  // ── Report & backup overlay ───────────────────────────────────────────────
  // A full-screen, read-only table of every bill/split/total, opened from the
  // Bills drawer. Full-screen like Help, so it participates in Back handling.
  reportOpen() {
    return root.hasAttribute("data-siano-report")
  },
  openReport() {
    root.setAttribute("data-siano-report", "")
    this.closeSortMenu() // never open on top of a stale sort popover
    History.sync()
  },
  closeReport() {
    root.removeAttribute("data-siano-report")
    History.sync()
  },

  // ── Bills sort popover ──────────────────────────────────────────────────────
  sortMenuOpen() {
    return root.hasAttribute("data-siano-sortmenu")
  },
  toggleSortMenu() {
    if (this.sortMenuOpen()) root.removeAttribute("data-siano-sortmenu")
    else root.setAttribute("data-siano-sortmenu", "")
    this.reflectSortMenu()
  },
  closeSortMenu() {
    root.removeAttribute("data-siano-sortmenu")
    this.reflectSortMenu()
  },
  // Keep the toggle button's aria-expanded truthful (the visual highlight is
  // handled by CSS keyed off :root, but ARIA can't be, so set it here).
  reflectSortMenu() {
    const btn = document.getElementById("bills-sort-btn")
    if (btn) btn.setAttribute("aria-expanded", String(this.sortMenuOpen()))
  },

  // Close every overlay through the normal history-aware path (used by the
  // system Back button, where popstate has already flagged closeFromPop so this
  // won't push another back()).
  closeAll() {
    root.removeAttribute("data-siano-drawer")
    root.removeAttribute("data-siano-help")
    root.removeAttribute("data-siano-report")
    root.removeAttribute("data-siano-sortmenu")
    this.reflectSortMenu()
    History.sync()
  },

  // Silently clear all overlays WITHOUT touching history — for live navigation
  // to a different trip, where LiveView is already managing the history stack
  // (calling history.back() here would bounce us off the new board). Mirrors the
  // old DrawerWatch "resync after nav" that just reset its pushed flag.
  reset() {
    root.removeAttribute("data-siano-drawer")
    root.removeAttribute("data-siano-help")
    root.removeAttribute("data-siano-report")
    root.removeAttribute("data-siano-sortmenu")
    this.reflectSortMenu()
    History.pushed = false
    History.closeFromPop = false
    History.programmatic = false
  }
}

// Installed once from app.js. Wires the system Back button and resets the
// overlays when navigating to another trip (the old server behaviour reset them
// on every mount, because the assigns started fresh).
export function installViewState() {
  window.addEventListener("popstate", () => {
    if (History.programmatic) {
      History.programmatic = false
      return
    }
    if (History.anyOpen()) {
      // system Back while an overlay is open -> close it, don't leave the app
      History.closeFromPop = true
      View.closeAll()
    }
  })

  // A live_navigate (New trip / switching trips) dispatches this with
  // kind === "redirect"; start the new board with nothing open. Silent reset —
  // LiveView owns the history stack across the navigation.
  window.addEventListener("phx:page-loading-stop", (e) => {
    if (e.detail && e.detail.kind === "redirect") View.reset()
  })
}

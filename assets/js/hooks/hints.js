import { sianoToast } from "./trips.js"

// First-run gesture hints ("coach marks").
//
// Big hand-drawn overlays that show *once* how each non-obvious gesture works —
// dragging a traveller up onto the board, swiping in from the left / right edge
// to open the drawers, and swiping the report table sideways. They are purely a
// per-viewer nicety, so (like the drawers and the pan/zoom transform) they live
// entirely on the client: nothing round-trips to the server. Whether this viewer
// has already seen one is remembered in localStorage (`siano:hints`), and while a
// hint is on screen its visibility is a data-attribute on :root
// (`data-siano-hint`) — morphdom never touches <html>, so a live re-render can't
// blink it away mid-show. The overlays are pointer-events:none, so the real
// gesture goes straight through them and, when it does, retires the hint.
//
// The three board-screen hints are shown one at a time, in order, so they never
// pile up (see BOARD_ORDER / boardTurn): a hint only offers itself once every
// earlier one has been seen and nothing else is currently on screen. The report
// hint is independent — it rides the report drawer opening.
//
// One hook drives every hint; each overlay element carries:
//   data-hint-key      unique localStorage key (see BOARD_ORDER + "report-scroll")
//   data-hint-trigger  "board" (main screen) | "report" (report drawer)
//   data-hint-seconds  how long to linger before auto-hiding (default 6)

const STORE = "siano:hints"

// The main-screen hints, in the order they should be taught.
const BOARD_ORDER = ["board-drag", "drawer-left", "drawer-right"]

function seenMap() {
  try {
    return JSON.parse(localStorage.getItem(STORE) || "{}") || {}
  } catch (_) {
    return {}
  }
}
function isSeen(key) {
  return !!seenMap()[key]
}
function markSeen(key) {
  const m = seenMap()
  m[key] = 1
  try {
    localStorage.setItem(STORE, JSON.stringify(m))
  } catch (_) {}
}
// This board hint's turn has come once every earlier one has been seen.
function boardTurn(key) {
  const i = BOARD_ORDER.indexOf(key)
  return i < 0 || BOARD_ORDER.slice(0, i).every(isSeen)
}

// Forget every "already seen" hint so the coach marks show again. Wired to the
// Settings "Show the tips again" button (delegated in gestures.js). The live Hint
// hooks re-arm on the broadcast event, so the hints come back without a reload.
// The InstallHint hook (hooks/install.js) listens to the same event and clears
// its own "dismissed" memory, so the home-screen banner is re-offered too.
export function resetHints() {
  try {
    localStorage.removeItem(STORE)
  } catch (_) {}
  window.dispatchEvent(new Event("siano:hints-reset"))
  sianoToast("Tips reset — they'll show again")
}

const ROOT = document.documentElement
const DRAWER_ATTRS = [
  "data-siano-drawer",
  "data-siano-help",
  "data-siano-report",
  "data-siano-sortmenu"
]
const anyOverlayOpen = () => DRAWER_ATTRS.some((a) => ROOT.hasAttribute(a))

export const Hint = {
  mounted() {
    this.key = this.el.dataset.hintKey
    this.trigger = this.el.dataset.hintTrigger
    this.seconds = parseFloat(this.el.dataset.hintSeconds) || 6

    // Doing the drag retires the board hint for good — even if it fired before
    // the hint appeared ("saw *or* used").
    this.onDrag = () => {
      if (this.key === "board-drag") this.retire()
    }
    this.onReset = () => this.rearm()
    window.addEventListener("siano:traveller-drag", this.onDrag)
    window.addEventListener("siano:hints-reset", this.onReset)

    // Re-evaluate whenever a drawer/overlay opens or closes, and whenever the
    // "currently showing" slot frees up (data-siano-hint) — that's what lets the
    // board hints advance one after another.
    this.watch = new MutationObserver(() => this.evaluate())
    this.watch.observe(ROOT, {
      attributes: true,
      attributeFilter: [...DRAWER_ATTRS, "data-siano-hint"]
    })

    this.arm()
  },

  arm() {
    if (isSeen(this.key)) return
    clearTimeout(this.armTimer)
    // Let the board settle / the report drawer slide in, then evaluate; the
    // MutationObserver drives everything after that.
    this.armTimer = setTimeout(() => this.evaluate(), this.trigger === "report" ? 400 : 700)
  },

  // The Settings "Show the tips again" button cleared localStorage; start over.
  rearm() {
    this.dismiss()
    this.scrollBound = false
    this.arm()
  },

  // Decide whether this hint should be pending/shown right now.
  evaluate() {
    if (isSeen(this.key)) return
    if (this.key === "report-scroll") return this.evaluateReport()

    // Board-screen hint. Performing the matching drawer swipe retires it.
    const drawer = ROOT.getAttribute("data-siano-drawer")
    if (
      (this.key === "drawer-left" && drawer === "bills") ||
      (this.key === "drawer-right" && drawer === "menu")
    ) {
      return this.retire()
    }
    // Only over a clear board, in turn, one hint at a time, and (for the drag)
    // with a traveller actually there to drag.
    if (anyOverlayOpen()) return this.cancelShow()
    if (!boardTurn(this.key)) return this.cancelShow()
    if (ROOT.hasAttribute("data-siano-hint")) return this.cancelShow()
    if (this.key === "board-drag" && !document.querySelector(".traveller-token")) {
      return this.cancelShow()
    }
    this.scheduleShow()
  },

  evaluateReport() {
    if (!ROOT.hasAttribute("data-siano-report")) {
      this.dismiss() // drawer closed — take the hint with it
      return
    }
    const s = document.getElementById("report-bills-scroll")
    if (!s) return
    // The first horizontal scroll retires it (even before it appears).
    if (!this.scrollBound) {
      this.scrollBound = true
      s.addEventListener("scroll", () => this.retire(), { passive: true, once: true })
    }
    // ...but only offer it when the table is actually wider than its viewport.
    if (s.scrollWidth - s.clientWidth > 24) this.show()
  },

  // Show after a short beat, so sequential hints have a breath between them.
  // Re-checks conditions at fire time (they may have changed while waiting).
  scheduleShow() {
    if (this.showTimer) return
    this.showTimer = setTimeout(() => {
      this.showTimer = null
      if (isSeen(this.key) || anyOverlayOpen()) return
      if (!boardTurn(this.key) || ROOT.hasAttribute("data-siano-hint")) return
      if (this.key === "board-drag" && !document.querySelector(".traveller-token")) return
      this.show()
    }, 500)
  },
  cancelShow() {
    if (this.showTimer) {
      clearTimeout(this.showTimer)
      this.showTimer = null
    }
  },

  show() {
    if (ROOT.getAttribute("data-siano-hint") === this.key) return // already up
    markSeen(this.key) // seeing it once is enough
    ROOT.setAttribute("data-siano-hint", this.key)
    clearTimeout(this.hideTimer)
    this.hideTimer = setTimeout(() => this.dismiss(), this.seconds * 1000)
  },

  // Gesture performed -> remember it and hide (covers doing it before it showed).
  retire() {
    markSeen(this.key)
    this.dismiss()
  },

  dismiss() {
    this.cancelShow()
    clearTimeout(this.armTimer)
    clearTimeout(this.hideTimer)
    if (ROOT.getAttribute("data-siano-hint") === this.key) {
      ROOT.removeAttribute("data-siano-hint") // CSS fades it out; frees the slot
    }
  },

  destroyed() {
    this.dismiss()
    window.removeEventListener("siano:traveller-drag", this.onDrag)
    window.removeEventListener("siano:hints-reset", this.onReset)
    if (this.watch) this.watch.disconnect()
  }
}

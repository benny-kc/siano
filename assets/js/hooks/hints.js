import { sianoToast } from "./trips.js"

// First-run gesture hints ("coach marks").
//
// Little hand-drawn overlays that show *once* how a non-obvious gesture works —
// dragging a traveller up onto the board, and swiping the report table sideways.
// They are purely a per-viewer nicety, so (like the drawers and the pan/zoom
// transform) they live entirely on the client: nothing round-trips to the
// server. Whether this viewer has already seen one is remembered in localStorage
// (`siano:hints`), and while a hint is on screen its visibility is a data-attribute
// on :root (`data-siano-hint`) — morphdom never touches <html>, so a live
// re-render can't blink it away mid-show. The overlays are pointer-events:none,
// so the real gesture goes straight through them and, when it does, dismisses
// (and permanently retires) the hint.
//
// One hook drives both hints; each overlay element carries:
//   data-hint-key      unique localStorage key ("board-drag" | "report-scroll")
//   data-hint-trigger  when to offer it ("board" | "report")
//   data-hint-seconds  how long to linger before auto-hiding (default 6)

const STORE = "siano:hints"

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

// Forget every "already seen" hint so the coach marks show again. Wired to the
// Settings "Show the tips again" button (delegated in gestures.js). The live Hint
// hooks re-arm on the broadcast event, so the hints come back without a reload —
// the board hint once the drawer is closed, the report hint on its next open.
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

    // Performing the drag retires the board hint for good — even if it fired
    // before the hint appeared ("saw *or* used").
    this.onDrag = () => {
      if (this.trigger === "board") this.retire()
    }
    this.onReset = () => this.rearm()
    window.addEventListener("siano:traveller-drag", this.onDrag)
    window.addEventListener("siano:hints-reset", this.onReset)

    // Re-evaluate whenever a drawer/overlay opens or closes: the report hint
    // shows when its drawer opens, the board hint waits until nothing covers the
    // board (e.g. after the Settings drawer where the reset lives is closed).
    this.watch = new MutationObserver(() => this.evaluate())
    this.watch.observe(ROOT, { attributes: true, attributeFilter: DRAWER_ATTRS })

    this.arm()
  },

  // Kick off a fresh chance to show, after a short settle (the board) or the
  // report drawer's slide-in; the MutationObserver covers everything after that.
  arm() {
    if (isSeen(this.key)) return
    clearTimeout(this.armTimer)
    this.armTimer = setTimeout(() => this.evaluate(), this.trigger === "report" ? 450 : 1100)
  },

  // The Settings "Show the tips again" button cleared localStorage; start over.
  rearm() {
    this.dismiss()
    this.scrollBound = false
    this.arm()
  },

  // Decide whether this hint should be on screen right now.
  evaluate() {
    if (isSeen(this.key)) return

    if (this.trigger === "board") {
      // Only over a clear board with something actually there to drag.
      if (anyOverlayOpen() || !document.querySelector(".traveller-token")) return
      this.show()
    } else if (this.trigger === "report") {
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
    clearTimeout(this.armTimer)
    clearTimeout(this.hideTimer)
    if (ROOT.getAttribute("data-siano-hint") === this.key) {
      ROOT.removeAttribute("data-siano-hint") // CSS fades it out
    }
  },

  destroyed() {
    this.dismiss()
    window.removeEventListener("siano:traveller-drag", this.onDrag)
    window.removeEventListener("siano:hints-reset", this.onReset)
    if (this.watch) this.watch.disconnect()
  }
}

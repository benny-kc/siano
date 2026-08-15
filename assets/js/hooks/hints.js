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
// the hint.
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

const ROOT = document.documentElement
const anyOverlayOpen = () =>
  ROOT.hasAttribute("data-siano-drawer") ||
  ROOT.hasAttribute("data-siano-help") ||
  ROOT.hasAttribute("data-siano-report") ||
  ROOT.hasAttribute("data-siano-sortmenu")

export const Hint = {
  mounted() {
    this.key = this.el.dataset.hintKey
    this.seconds = parseFloat(this.el.dataset.hintSeconds) || 6
    if (!this.key || isSeen(this.key)) return // shown before -> never again

    if (this.el.dataset.hintTrigger === "board") this.armBoard()
    else if (this.el.dataset.hintTrigger === "report") this.armReport()
  },

  // The board hint: a beat after load, if there's actually a traveller to drag
  // and nothing is covering the board. Performing the drag retires it for good —
  // even if it fired before the hint had a chance to appear ("saw *or* used").
  armBoard() {
    this.onDrag = () => this.retire()
    window.addEventListener("siano:traveller-drag", this.onDrag)
    this.startTimer = setTimeout(() => {
      if (isSeen(this.key) || anyOverlayOpen()) return
      if (!document.querySelector(".traveller-token")) return
      this.show()
    }, 1100)
  },

  // The report hint: when the report drawer opens *and* the table is actually
  // wider than its viewport (otherwise there's nothing to swipe for). The first
  // horizontal scroll retires it (again, even before it appears); closing the
  // drawer takes it away.
  armReport() {
    this.obs = new MutationObserver(() => {
      if (!ROOT.hasAttribute("data-siano-report")) {
        this.dismiss() // drawer closed — take the hint with it
        return
      }
      if (isSeen(this.key)) return
      const s = document.getElementById("report-bills-scroll")
      if (s && !this.scrollBound) {
        this.scrollBound = true
        s.addEventListener("scroll", () => this.retire(), { passive: true, once: true })
      }
      // Wait out the drawer's slide-in (300ms) so the table has laid out.
      clearTimeout(this.startTimer)
      this.startTimer = setTimeout(() => {
        if (isSeen(this.key) || !ROOT.hasAttribute("data-siano-report")) return
        const el = document.getElementById("report-bills-scroll")
        if (el && el.scrollWidth - el.clientWidth > 24) this.show()
      }, 450)
    })
    this.obs.observe(ROOT, { attributes: true, attributeFilter: ["data-siano-report"] })
  },

  show() {
    markSeen(this.key) // seeing it once is enough
    ROOT.setAttribute("data-siano-hint", this.key)
    this.hideTimer = setTimeout(() => this.dismiss(), this.seconds * 1000)
  },

  // Gesture performed -> remember it and hide (covers doing it before it showed).
  retire() {
    markSeen(this.key)
    this.dismiss()
  },

  dismiss() {
    clearTimeout(this.startTimer)
    clearTimeout(this.hideTimer)
    if (ROOT.getAttribute("data-siano-hint") === this.key) {
      ROOT.removeAttribute("data-siano-hint") // CSS fades it out
    }
  },

  destroyed() {
    this.dismiss()
    if (this.onDrag) window.removeEventListener("siano:traveller-drag", this.onDrag)
    if (this.obs) this.obs.disconnect()
  }
}

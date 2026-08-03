// Siano client entry point.
//
// The whole "game" is two gestures:
//   1. Drag a traveller token onto a meal card  -> add them to the split.
//   2. Drag a meal card by its handle           -> reposition it on the board.
// Both are built on the Pointer Events API (not HTML5 drag-and-drop, which does
// not work on touch devices — and this app is meant to be used from a phone).
//
// All client behaviour lives in LiveView Hooks, one concern per module under
// ./hooks (with shared state/util in ./lib). This file only wires them together
// and boots the LiveSocket. See CLAUDE.md for the morphdom re-render gotchas.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"

// Installs the whole-app network meter. Imported first (and for its side
// effect) so it wraps window.WebSocket before the LiveSocket below creates one.
import "./lib/net.js"

import { NetSpeed } from "./hooks/net_speed.js"
import { PanZoom } from "./hooks/pan_zoom.js"
import { Traveller } from "./hooks/traveller.js"
import { FieldLabel } from "./hooks/field_label.js"
import { MealCard } from "./hooks/meal_card.js"
import { Gestures } from "./hooks/gestures.js"
import { QR, Confirm } from "./hooks/dialogs.js"
import { Ledger, TripSwitcher } from "./hooks/trips.js"
import { PhotoUpload, TopPhoto, BillPhoto } from "./hooks/photos.js"
import { LocalTime, Focus, LongPress, AmountField } from "./hooks/misc.js"
import { DrawerWatch } from "./hooks/drawers.js"

const Hooks = {
  NetSpeed,
  PanZoom,
  Traveller,
  FieldLabel,
  MealCard,
  Gestures,
  QR,
  Confirm,
  Ledger,
  TripSwitcher,
  PhotoUpload,
  TopPhoto,
  BillPhoto,
  LocalTime,
  Focus,
  LongPress,
  AmountField,
  DrawerWatch
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: { _csrf_token: csrfToken },
  hooks: Hooks
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// Register the service worker so Siano can be installed to the home screen and
// launched full-screen (no browser address bar).
if ("serviceWorker" in navigator) {
  window.addEventListener("load", () => {
    navigator.serviceWorker.register("/service-worker.js").catch(() => {})
  })
}

// Make it feel like an app: enter full-screen on the first tap, and — since a
// dialog, a permission prompt, or switching away and back all silently drop
// full-screen — restore it on the next tap whenever it has been lost.
//
// Browsers only allow requesting full-screen from a user gesture, so we can't
// re-enter the instant it's lost; instead we remember that full-screen is
// "desired" and re-request on the next interaction. Pressing Escape is treated
// as a deliberate exit, so we stop restoring until the user opts back in.
// Skipped when already running as an installed PWA (already full-screen) or
// where the API is unavailable (e.g. iPhone Safari — install to home screen).
;(function fullscreenManager() {
  const standalone =
    window.matchMedia("(display-mode: fullscreen)").matches ||
    window.matchMedia("(display-mode: standalone)").matches ||
    window.navigator.standalone === true

  const root = document.documentElement
  if (standalone || !root.requestFullscreen) return

  let desired = false
  let everEntered = false

  const request = () => {
    if (document.fullscreenElement) return
    root
      .requestFullscreen()
      .then(() => {
        desired = true
        everEntered = true
      })
      .catch(() => {})
  }

  const onGesture = () => {
    if (document.fullscreenElement) return
    // enter on the very first gesture; afterwards only restore if still wanted
    if (!everEntered || desired) request()
  }

  document.addEventListener("click", onGesture)
  document.addEventListener("touchend", onGesture, { passive: true })
  document.addEventListener("keydown", (e) => {
    if (e.key === "Escape") {
      desired = false // deliberate exit — stop auto-restoring
      return
    }
    onGesture()
  })
})()

// expose liveSocket on window for web console debug logs and latency simulator:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
window.liveSocket = liveSocket

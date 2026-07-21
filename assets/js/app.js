// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below to enable it.
//
//     import "./user_socket.js"

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"

// ── Drag & drop hooks ──────────────────────────────────────────────────────
//
// The whole "game" is two gestures:
//   1. Drag a traveller token onto a meal card  -> add them to the split.
//   2. Drag a meal card by its handle           -> reposition it on the board.
//
// Both are built on the Pointer Events API (pointerdown/move/up) rather than
// the HTML5 Drag & Drop API, because HTML5 drag-and-drop does NOT work on
// touch devices (phones/tablets) — and this app is meant to be used from a
// phone. Pointer events give us one code path for mouse, touch and pen.

const Hooks = {}

// Find the meal card element sitting under a screen point. The drag "ghost"
// has pointer-events:none, so elementFromPoint sees through it to the card.
function mealCardAt(x, y) {
  const el = document.elementFromPoint(x, y)
  return el && el.closest(".meal-card")
}

function clearDropHighlights() {
  document
    .querySelectorAll(".dropzone--over")
    .forEach((z) => z.classList.remove("dropzone--over"))
}

// A traveller token you pick up and drop onto a meal.
Hooks.Traveller = {
  mounted() {
    const el = this.el
    let pointerId = null
    let ghost = null
    let currentCard = null

    const highlight = (card) => {
      if (card === currentCard) return
      clearDropHighlights()
      currentCard = card
      if (card) {
        const zone = card.querySelector(".dropzone")
        if (zone) zone.classList.add("dropzone--over")
      }
    }

    const onMove = (e) => {
      if (pointerId === null || e.pointerId !== pointerId) return
      if (ghost) {
        ghost.style.left = `${e.clientX}px`
        ghost.style.top = `${e.clientY}px`
      }
      highlight(mealCardAt(e.clientX, e.clientY))
    }

    const finish = (e) => {
      if (pointerId === null || e.pointerId !== pointerId) return
      const card = mealCardAt(e.clientX, e.clientY)

      if (ghost) { ghost.remove(); ghost = null }
      el.classList.remove("opacity-40")
      window.removeEventListener("pointermove", onMove)
      window.removeEventListener("pointerup", finish)
      window.removeEventListener("pointercancel", finish)
      try { el.releasePointerCapture(pointerId) } catch (_) {}
      pointerId = null
      // clear the drag flag on the next tick so the trailing touchend (which
      // fires around the same time) still sees that a drag was in progress.
      setTimeout(() => { window.__sianoDragging = false }, 0)
      clearDropHighlights()
      currentCard = null

      if (card) {
        card.classList.remove("pulse")
        void card.offsetWidth // restart the animation
        card.classList.add("pulse")
        this.pushEvent("drop_on_meal", {
          meal_id: card.dataset.mealId,
          member_id: el.dataset.memberId
        })
      }
    }

    el.addEventListener("pointerdown", (e) => {
      if (e.button != null && e.button > 0) return // ignore right/middle click
      e.preventDefault()
      pointerId = e.pointerId
      window.__sianoDragging = true
      try { el.setPointerCapture(pointerId) } catch (_) {}
      el.classList.add("opacity-40")

      // Build a floating clone that follows the pointer.
      const rect = el.getBoundingClientRect()
      ghost = el.cloneNode(true)
      ghost.removeAttribute("id")
      ghost.removeAttribute("phx-hook")
      ghost.classList.add("drag-ghost")
      ghost.style.width = `${rect.width}px`
      ghost.style.left = `${e.clientX}px`
      ghost.style.top = `${e.clientY}px`
      document.body.appendChild(ghost)

      window.addEventListener("pointermove", onMove)
      window.addEventListener("pointerup", finish)
      window.addEventListener("pointercancel", finish)
    })
  }
}

// Shared stacking counter so the most recently created / opened / touched meal
// card always sits on top of the others.
let mealZ = 10
function bringToFront(card) {
  mealZ += 1
  card.style.zIndex = String(mealZ)
}

// A meal card can be repositioned on the board by dragging its handle.
Hooks.MealCard = {
  mounted() {
    const card = this.el
    // A newly added or re-opened card comes to the front...
    bringToFront(card)
    // ...and is nudged fully inside the board so it is never off-screen.
    this.clampIntoView(card)

    const handle = card.querySelector(".drag-handle")
    if (handle) this.enableDragging(card, handle)
  },

  // Keep the card within its board, persisting the correction if it was out of
  // bounds (e.g. created off-screen, or the viewport is smaller than last time).
  clampIntoView(card) {
    const board = card.parentElement
    if (!board) return
    const bw = board.clientWidth
    const bh = board.clientHeight
    const M = 8
    const x = parseFloat(card.style.left) || 0
    const y = parseFloat(card.style.top) || 0
    const maxX = Math.max(M, bw - card.offsetWidth - M)
    const maxY = Math.max(M, bh - card.offsetHeight - M)
    const nx = Math.min(Math.max(x, M), maxX)
    const ny = Math.min(Math.max(y, M), maxY)

    if (nx !== x || ny !== y) {
      card.style.left = `${nx}px`
      card.style.top = `${ny}px`
      card.dataset.x = nx
      card.dataset.y = ny
      this.pushEvent("move_meal", { meal_id: card.dataset.mealId, x: nx, y: ny })
    }
  },

  enableDragging(card, handle) {
    let startX, startY, originLeft, originTop, pointerId = null

    const onMove = (e) => {
      if (pointerId === null || e.pointerId !== pointerId) return
      const board = card.parentElement.getBoundingClientRect()
      let left = originLeft + (e.clientX - startX)
      let top = originTop + (e.clientY - startY)
      left = Math.max(0, Math.min(left, board.width - card.offsetWidth))
      top = Math.max(0, Math.min(top, board.height - card.offsetHeight))
      card.style.left = `${left}px`
      card.style.top = `${top}px`
      card.dataset.x = left
      card.dataset.y = top
    }

    const onUp = (e) => {
      if (pointerId === null || e.pointerId !== pointerId) return
      card.classList.remove("shadow-2xl")
      window.removeEventListener("pointermove", onMove)
      window.removeEventListener("pointerup", onUp)
      window.removeEventListener("pointercancel", onUp)
      try { handle.releasePointerCapture(pointerId) } catch (_) {}
      pointerId = null
      setTimeout(() => { window.__sianoDragging = false }, 0)
      this.pushEvent("move_meal", {
        meal_id: card.dataset.mealId,
        x: parseFloat(card.dataset.x),
        y: parseFloat(card.dataset.y)
      })
    }

    handle.addEventListener("pointerdown", (e) => {
      e.preventDefault()
      e.stopPropagation()
      pointerId = e.pointerId
      window.__sianoDragging = true
      try { handle.setPointerCapture(pointerId) } catch (_) {}
      startX = e.clientX
      startY = e.clientY
      originLeft = parseFloat(card.style.left) || 0
      originTop = parseFloat(card.style.top) || 0
      bringToFront(card)
      card.classList.add("shadow-2xl")
      window.addEventListener("pointermove", onMove)
      window.addEventListener("pointerup", onUp)
      window.addEventListener("pointercancel", onUp)
    })
  }
}

// Edge-swipe gestures for the two drawers, mirroring the buttons:
//   • swipe in from the LEFT edge  -> open Bills   (left drawer)
//   • swipe in from the RIGHT edge -> open Settings (right drawer)
//   • while Bills is open,   swipe left  -> close it
//   • while Settings is open, swipe right -> close it
// It toggles exactly the same classes the phx-click handlers use, so the two
// stay in sync. Touch-only, so it never interferes with mouse use on desktop.
Hooks.Gestures = {
  mounted() {
    const EDGE = 28 // px from a screen border where an "open" swipe may start
    const THRESH = 60 // px of horizontal travel required to count as a swipe
    const RATIO = 1.7 // swipe must be this much more horizontal than vertical
    const MAX_DY = 55 // and never wander too far vertically (that's a drag/scroll)

    // tracking state for the single active touch
    let x0 = null, y0 = null, startedOnDraggable = false, invalid = false

    const el = (id) => document.getElementById(id)
    const billsOpen = () => el("bills") && !el("bills").classList.contains("-translate-x-full")
    const menuOpen = () => el("menu") && !el("menu").classList.contains("translate-x-full")

    const openBills = () => {
      closeMenu()
      el("bills").classList.remove("-translate-x-full")
      el("bills-backdrop").classList.remove("opacity-0", "pointer-events-none")
    }
    const closeBills = () => {
      el("bills").classList.add("-translate-x-full")
      el("bills-backdrop").classList.add("opacity-0", "pointer-events-none")
    }
    const openMenu = () => {
      closeBills()
      el("menu").classList.remove("translate-x-full")
      el("menu-backdrop").classList.remove("opacity-0", "pointer-events-none")
    }
    const closeMenu = () => {
      el("menu").classList.add("translate-x-full")
      el("menu-backdrop").classList.add("opacity-0", "pointer-events-none")
    }

    this.el.addEventListener("touchstart", (e) => {
      // ignore multi-touch, and any gesture that begins on something draggable
      // (a traveller token or a meal card) — that's a drag, not a swipe.
      if (e.touches.length !== 1) { invalid = true; x0 = null; return }
      const t = e.touches[0]
      x0 = t.clientX
      y0 = t.clientY
      startedOnDraggable = !!e.target.closest(".traveller-token, .meal-card, .drag-handle")
      invalid = false
    }, { passive: true })

    this.el.addEventListener("touchmove", (e) => {
      // if a drag kicks in mid-gesture, abandon any swipe interpretation
      if (x0 !== null && window.__sianoDragging) invalid = true
    }, { passive: true })

    this.el.addEventListener("touchend", (e) => {
      const startX = x0
      const bad = invalid || startedOnDraggable || window.__sianoDragging
      x0 = null
      startedOnDraggable = false
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

// expose liveSocket on window for web console debug logs and latency simulator:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
window.liveSocket = liveSocket

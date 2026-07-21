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

// A meal card can be repositioned on the board by dragging its handle.
Hooks.MealCard = {
  mounted() {
    const card = this.el
    const handle = card.querySelector(".drag-handle")
    if (handle) this.enableDragging(card, handle)
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
      card.classList.remove("z-50", "shadow-2xl")
      window.removeEventListener("pointermove", onMove)
      window.removeEventListener("pointerup", onUp)
      window.removeEventListener("pointercancel", onUp)
      try { handle.releasePointerCapture(pointerId) } catch (_) {}
      pointerId = null
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
      try { handle.setPointerCapture(pointerId) } catch (_) {}
      startX = e.clientX
      startY = e.clientY
      originLeft = parseFloat(card.style.left) || 0
      originTop = parseFloat(card.style.top) || 0
      card.classList.add("z-50", "shadow-2xl")
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
    const EDGE = 30 // px from a screen border where an "open" swipe may start
    const THRESH = 55 // px of horizontal travel required to count as a swipe
    let x0 = null, y0 = null

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
      if (e.touches.length !== 1) { x0 = null; return }
      x0 = e.touches[0].clientX
      y0 = e.touches[0].clientY
    }, { passive: true })

    this.el.addEventListener("touchend", (e) => {
      if (x0 === null) return
      const t = e.changedTouches[0]
      const dx = t.clientX - x0
      const dy = t.clientY - y0
      const startX = x0
      x0 = null

      // must be a clearly horizontal swipe
      if (Math.abs(dx) < THRESH || Math.abs(dx) <= Math.abs(dy)) return

      if (billsOpen()) {
        if (dx < 0) closeBills()
      } else if (menuOpen()) {
        if (dx > 0) closeMenu()
      } else if (dx > 0 && startX <= EDGE) {
        openBills()
      } else if (dx < 0 && startX >= window.innerWidth - EDGE) {
        openMenu()
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

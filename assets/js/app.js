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
// We use the native HTML5 drag & drop API for (1) and pointer events for (2)
// so the two never fight over the same gesture.

const Hooks = {}

// A traveller token becomes the thing you pick up and drag.
Hooks.Traveller = {
  mounted() {
    this.el.addEventListener("dragstart", (e) => {
      e.dataTransfer.setData("text/member-id", this.el.dataset.memberId)
      e.dataTransfer.effectAllowed = "copy"
      this.el.classList.add("opacity-40")
    })
    this.el.addEventListener("dragend", () => {
      this.el.classList.remove("opacity-40")
    })
  }
}

// A meal card is both a drop target (for travellers) and movable by its handle.
Hooks.MealCard = {
  mounted() {
    const card = this.el
    const zone = card.querySelector(".dropzone")

    // --- (1) drop target for travellers ---
    const activate = (on) => zone && zone.classList.toggle("dropzone--over", on)

    card.addEventListener("dragover", (e) => {
      e.preventDefault()
      e.dataTransfer.dropEffect = "copy"
      activate(true)
    })
    card.addEventListener("dragleave", (e) => {
      if (!card.contains(e.relatedTarget)) activate(false)
    })
    card.addEventListener("drop", (e) => {
      e.preventDefault()
      activate(false)
      const memberId = e.dataTransfer.getData("text/member-id")
      if (!memberId) return
      card.classList.remove("pulse")
      void card.offsetWidth // restart the animation
      card.classList.add("pulse")
      this.pushEvent("drop_on_meal", { meal_id: card.dataset.mealId, member_id: memberId })
    })

    // --- (2) move the card around the board via its handle ---
    const handle = card.querySelector(".drag-handle")
    if (handle) this.enableDragging(card, handle)
  },

  enableDragging(card, handle) {
    let startX, startY, originLeft, originTop, dragging = false

    const onMove = (e) => {
      if (!dragging) return
      const board = card.parentElement.getBoundingClientRect()
      let left = originLeft + (e.clientX - startX)
      let top = originTop + (e.clientY - startY)
      // keep the card inside the board surface
      left = Math.max(0, Math.min(left, board.width - card.offsetWidth))
      top = Math.max(0, Math.min(top, board.height - card.offsetHeight))
      card.style.left = `${left}px`
      card.style.top = `${top}px`
      card.dataset.x = left
      card.dataset.y = top
    }

    const onUp = () => {
      if (!dragging) return
      dragging = false
      card.classList.remove("z-50", "shadow-2xl")
      document.removeEventListener("pointermove", onMove)
      document.removeEventListener("pointerup", onUp)
      this.pushEvent("move_meal", {
        meal_id: card.dataset.mealId,
        x: parseFloat(card.dataset.x),
        y: parseFloat(card.dataset.y)
      })
    }

    handle.addEventListener("pointerdown", (e) => {
      e.preventDefault()
      dragging = true
      startX = e.clientX
      startY = e.clientY
      originLeft = parseFloat(card.style.left) || 0
      originTop = parseFloat(card.style.top) || 0
      card.classList.add("z-50", "shadow-2xl")
      document.addEventListener("pointermove", onMove)
      document.addEventListener("pointerup", onUp)
    })
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

// expose liveSocket on window for web console debug logs and latency simulator:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
window.liveSocket = liveSocket

import { BoardView } from "../lib/board.js"
import { selectedMember, setSelectedTraveller } from "../lib/selection.js"

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

// A traveller token: TAP to arm it for field-assignment (single-select), or
// DRAG onto a meal (add them to the split) / onto empty board (new meal). We
// tell the two apart by movement: below DRAG_THRESH px it's a tap, beyond it a
// drag (at which point the floating ghost appears).
const DRAG_THRESH = 8
export const Traveller = {
  mounted() {
    const el = this.el
    let pointerId = null
    let ghost = null
    let currentCard = null
    let startX = 0, startY = 0, dragging = false

    const highlight = (card) => {
      if (card === currentCard) return
      clearDropHighlights()
      currentCard = card
      if (card) {
        const zone = card.querySelector(".dropzone")
        if (zone) zone.classList.add("dropzone--over")
      }
    }

    const beginDrag = (e) => {
      dragging = true
      window.__sianoDragging = true
      // Let the first-run board hint (hooks/hints.js) retire the moment the user
      // actually performs the drag it was demonstrating.
      window.dispatchEvent(new Event("siano:traveller-drag"))
      el.classList.add("opacity-40")
      const rect = el.getBoundingClientRect()
      ghost = el.cloneNode(true)
      ghost.removeAttribute("id")
      ghost.removeAttribute("phx-hook")
      ghost.classList.remove("is-selected")
      // The token carries `animate-pop` (animation: pop ... both). Because it's a
      // *clone*, that animation re-fires, and its `both` fill-mode leaves the final
      // keyframe (transform: scale(1)) applied for good. Animated values outrank
      // normal declarations in the cascade, so it was silently clobbering
      // `.drag-ghost`'s transform (the 3x scale + finger offset). Strip it here.
      ghost.classList.remove("animate-pop")
      ghost.classList.add("drag-ghost")
      ghost.style.width = `${rect.width}px`
      ghost.style.left = `${e.clientX}px`
      ghost.style.top = `${e.clientY}px`
      document.body.appendChild(ghost)
    }

    const onMove = (e) => {
      if (pointerId === null || e.pointerId !== pointerId) return
      if (!dragging) {
        // promote to a drag only once the finger/mouse has travelled far enough
        if (Math.abs(e.clientX - startX) > DRAG_THRESH || Math.abs(e.clientY - startY) > DRAG_THRESH) {
          beginDrag(e)
        } else {
          return
        }
      }
      if (ghost) {
        ghost.style.left = `${e.clientX}px`
        ghost.style.top = `${e.clientY}px`
      }
      highlight(mealCardAt(e.clientX, e.clientY))
    }

    const finish = (e) => {
      if (pointerId === null || e.pointerId !== pointerId) return
      const wasDragging = dragging
      const card = wasDragging ? mealCardAt(e.clientX, e.clientY) : null

      if (ghost) { ghost.remove(); ghost = null }
      el.classList.remove("opacity-40")
      window.removeEventListener("pointermove", onMove)
      window.removeEventListener("pointerup", finish)
      window.removeEventListener("pointercancel", finish)
      try { el.releasePointerCapture(pointerId) } catch (_) {}
      pointerId = null
      dragging = false
      // clear the drag flag on the next tick so the trailing touchend (which
      // fires around the same time) still sees that a drag was in progress.
      setTimeout(() => { window.__sianoDragging = false }, 0)
      clearDropHighlights()
      currentCard = null

      // A tap (no drag) toggles this traveller's field-assignment selection.
      if (!wasDragging) {
        setSelectedTraveller(el.dataset.memberId)
        return
      }

      if (card) {
        card.classList.remove("pulse")
        void card.offsetWidth // restart the animation
        card.classList.add("pulse")
        this.pushEvent("drop_on_meal", {
          meal_id: card.dataset.mealId,
          member_id: el.dataset.memberId
        })
      } else {
        // Dropped on empty board space -> start a new meal with this traveller.
        const board = document.getElementById("board-surface")
        if (board) {
          const b = board.getBoundingClientRect()
          if (e.clientX >= b.left && e.clientX <= b.right && e.clientY >= b.top && e.clientY <= b.bottom) {
            const c = BoardView.toCanvas(e.clientX, e.clientY, b)
            this.pushEvent("drop_on_board", {
              member_id: el.dataset.memberId,
              x: Math.round(c.x - 128),
              y: Math.round(c.y - 24)
            })
          }
        }
      }
    }

    el.addEventListener("pointerdown", (e) => {
      if (e.button != null && e.button > 0) return // ignore right/middle click
      e.preventDefault()
      pointerId = e.pointerId
      startX = e.clientX
      startY = e.clientY
      dragging = false
      try { el.setPointerCapture(pointerId) } catch (_) {}

      window.addEventListener("pointermove", onMove)
      window.addEventListener("pointerup", finish)
      window.addEventListener("pointercancel", finish)
    })
  },
  updated() {
    // keep the highlight after a re-render (the selected token may be re-rendered)
    this.el.classList.toggle("is-selected", this.el.dataset.memberId === selectedMember)
  }
}


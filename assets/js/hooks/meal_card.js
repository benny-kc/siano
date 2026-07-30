import { BoardView } from "../lib/board.js"
import { selectedMember } from "../lib/selection.js"
import { bringToFront, applyZ } from "../lib/zorder.js"

// A meal card can be repositioned on the board by dragging its handle.
export const MealCard = {
  mounted() {
    const card = this.el
    // A newly added or re-opened card comes to the front...
    bringToFront(card)
    // ...and is nudged fully inside the board so it is never off-screen.
    this.clampIntoView(card)

    // Any interaction with the card raises it (and marks it "most recently used"
    // for the top-bar camera). Capture phase so it wins even inside children.
    card.addEventListener("pointerdown", () => bringToFront(card), true)

    // Any handle (the grip and the meal emoji) can move the card.
    card.querySelectorAll(".drag-handle").forEach((handle) => this.enableDragging(card, handle))

    // Tapping a recognised price field assigns (or unassigns) it to the
    // currently selected traveller. Assigned fields are summed into that
    // traveller's custom share. With nobody selected the tap is ignored.
    card.addEventListener("click", (e) => {
      const field = e.target.closest(".field-overlay")
      if (!field || !card.contains(field)) return
      // With nobody armed in the dock, tapping a field does nothing — you can
      // only (de)select fields for the currently selected traveller.
      if (!selectedMember) return
      this.pushEvent("assign_field", {
        meal_id: card.dataset.mealId,
        photo_id: field.dataset.photoId,
        index: parseInt(field.dataset.index, 10),
        member_id: selectedMember
      })
    })
  },

  // Re-apply the stacking order after a re-render (morphdom resets the inline
  // style to the server's, which has no z-index), so a moved / just-opened card
  // stays on top instead of dropping behind the others.
  updated() {
    applyZ(this.el)
  },

  // Nudge a newly added / re-opened card into the currently visible part of the
  // (pannable, zoomable) board, so it always appears on screen — computed in
  // canvas coordinates from the current pan/zoom.
  clampIntoView(card) {
    const board = document.getElementById("board-surface")
    if (!board) return
    const s = BoardView.scale
    const M = 8 / s
    const visLeft = -BoardView.panX / s
    const visTop = -BoardView.panY / s
    const visRight = (board.clientWidth - BoardView.panX) / s
    const visBottom = (board.clientHeight - BoardView.panY) / s

    const x = parseFloat(card.style.left) || 0
    const y = parseFloat(card.style.top) || 0
    const nx = Math.min(Math.max(x, visLeft + M), Math.max(visLeft + M, visRight - card.offsetWidth - M))
    const ny = Math.min(Math.max(y, visTop + M), Math.max(visTop + M, visBottom - card.offsetHeight - M))

    if (Math.round(nx) !== Math.round(x) || Math.round(ny) !== Math.round(y)) {
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
      // screen delta -> canvas delta (divide by zoom); the canvas is pannable,
      // so cards are free to sit anywhere.
      const left = originLeft + (e.clientX - startX) / BoardView.scale
      const top = originTop + (e.clientY - startY) / BoardView.scale
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


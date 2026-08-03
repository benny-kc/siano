import { BoardView } from "../lib/board.js"
import { selectedMember } from "../lib/selection.js"
import { amountArmedFor, endAmountArm } from "../lib/amount.js"

// A recognised-price label sitting beside its bill field. It can be dragged to
// nudge it clear of the image / other labels. The offset is kept per label
// (photoId:index) in this session-scoped map and re-applied after every
// LiveView re-render (which would otherwise reset the inline transform).
const fieldLabelPos = {}
const FL_TAP = 5 // px of movement below which a press counts as a tap (edit)
export const FieldLabel = {
  mounted() {
    this.key = this.el.dataset.key
    this.apply()
    this.ensureConnector()
    this.draw()

    // redraw the connector when the photo lays out (image load) or the window
    // resizes — the field/label geometry shifts but their relation must hold.
    this.ro = new ResizeObserver(() => this.draw())
    this.ro.observe(this.container())

    let pointerId = null, sx = 0, sy = 0, base = null, dragging = false

    const onMove = (e) => {
      if (pointerId === null || e.pointerId !== pointerId) return
      if (!dragging) {
        if (Math.abs(e.clientX - sx) <= FL_TAP && Math.abs(e.clientY - sy) <= FL_TAP) return
        dragging = true
        window.__sianoDragging = true
      }
      // screen delta -> canvas delta (the label lives inside the zoomable board)
      const dx = base.dx + (e.clientX - sx) / BoardView.scale
      const dy = base.dy + (e.clientY - sy) / BoardView.scale
      fieldLabelPos[this.key] = { dx, dy }
      this.apply()
      this.draw()
    }

    const onUp = (e) => {
      if (pointerId === null || e.pointerId !== pointerId) return
      const wasDragging = dragging
      window.removeEventListener("pointermove", onMove)
      window.removeEventListener("pointerup", onUp)
      window.removeEventListener("pointercancel", onUp)
      try { this.el.releasePointerCapture(pointerId) } catch (_) {}
      pointerId = null
      dragging = false
      setTimeout(() => { window.__sianoDragging = false }, 0)
      // A tap (no drag):
      //  - If the Total input is focused for writing, write this field's value
      //    into the meal total (mirrors tapping the field border; see MealCard).
      //  - Else if a traveller is armed in the dock, assign/unassign the label to
      //    that traveller (treated like its field border).
      //  - Else open the inline editor to correct the OCR value.
      if (!wasDragging) {
        const mealId = this.el.closest(".meal-card").dataset.mealId
        if (amountArmedFor(mealId)) {
          this.pushEvent("set_amount_from_field", {
            meal_id: mealId,
            photo_id: this.el.dataset.photoId,
            index: parseInt(this.el.dataset.index, 10)
          })
          endAmountArm(mealId)
        } else if (selectedMember) {
          this.pushEvent("assign_field", {
            meal_id: mealId,
            photo_id: this.el.dataset.photoId,
            index: parseInt(this.el.dataset.index, 10),
            member_id: selectedMember
          })
        } else {
          this.enterEdit()
        }
      }
    }

    this.el.addEventListener("pointerdown", (e) => {
      if (e.button != null && e.button > 0) return
      if (this.el.isContentEditable) return // let the caret work while editing
      e.preventDefault()
      e.stopPropagation() // don't start a card drag / field tap
      pointerId = e.pointerId
      sx = e.clientX
      sy = e.clientY
      dragging = false
      base = fieldLabelPos[this.key] || { dx: 0, dy: 0 }
      try { this.el.setPointerCapture(pointerId) } catch (_) {}
      window.addEventListener("pointermove", onMove)
      window.addEventListener("pointerup", onUp)
      window.addEventListener("pointercancel", onUp)
    })
  },
  updated() {
    if (this.el.isContentEditable) return // don't clobber an in-progress edit
    this.apply()
    this.draw()
  },
  destroyed() {
    if (this.ro) this.ro.disconnect()
    if (this.line) this.line.remove()
  },
  container() {
    return this.el.parentElement
  },
  apply() {
    const p = fieldLabelPos[this.key] || { dx: 0, dy: 0 }
    // compose the drag offset on top of the server-provided vertical centring
    this.el.style.transform = `translateY(-50%) translate(${p.dx}px, ${p.dy}px)`
  },
  // The dotted line for this label lives in the photo's connector SVG (rendered
  // by the template with phx-update=ignore, so LiveView won't prune it).
  ensureConnector() {
    const svg = this.container().querySelector("svg.field-connectors")
    if (!svg) return
    this.line = document.createElementNS("http://www.w3.org/2000/svg", "line")
    this.line.setAttribute("stroke-width", "1")
    this.line.setAttribute("stroke-dasharray", "2 2")
    this.line.setAttribute("stroke-opacity", "0.3")
    svg.appendChild(this.line)
  },
  // Draw the dotted line from the field's near edge to the label's near edge,
  // in the container's own (unscaled) coordinate space so it is zoom-safe.
  draw() {
    if (!this.line) return
    const c = this.container()
    const btn = c.querySelector(
      `.field-overlay[data-photo-id="${CSS.escape(this.el.dataset.photoId)}"][data-index="${this.el.dataset.index}"]`
    )
    if (!btn) return
    const s = BoardView.scale || 1
    const cr = c.getBoundingClientRect()
    const b = btn.getBoundingClientRect()
    const l = this.el.getBoundingClientRect()
    const onLeft = (l.left + l.right) / 2 < (b.left + b.right) / 2
    const fpx = onLeft ? b.left : b.right
    const lpx = onLeft ? l.right : l.left
    const X = (v) => (v - cr.left) / s
    const Y = (v) => (v - cr.top) / s
    this.line.setAttribute("x1", X(fpx))
    this.line.setAttribute("y1", Y((b.top + b.bottom) / 2))
    this.line.setAttribute("x2", X(lpx))
    this.line.setAttribute("y2", Y((l.top + l.bottom) / 2))
    this.line.setAttribute("stroke", getComputedStyle(this.el).color)
  },
  enterEdit() {
    const el = this.el
    this.original = el.textContent
    el.contentEditable = "true"
    el.classList.add("is-editing")
    el.focus()
    const range = document.createRange()
    range.selectNodeContents(el)
    const sel = window.getSelection()
    sel.removeAllRanges()
    sel.addRange(range)

    const done = (save) => {
      el.removeEventListener("blur", onBlur)
      el.removeEventListener("keydown", onKey)
      el.contentEditable = "false"
      el.classList.remove("is-editing")
      if (save) {
        this.pushEvent("correct_field", {
          meal_id: el.closest(".meal-card").dataset.mealId,
          photo_id: el.dataset.photoId,
          index: parseInt(el.dataset.index, 10),
          value: el.textContent.trim()
        })
      } else {
        el.textContent = this.original
      }
    }
    const onBlur = () => done(true)
    const onKey = (e) => {
      if (e.key === "Enter") { e.preventDefault(); el.blur() }
      else if (e.key === "Escape") { e.preventDefault(); done(false) }
    }
    el.addEventListener("blur", onBlur)
    el.addEventListener("keydown", onKey)
  }
}


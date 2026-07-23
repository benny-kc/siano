// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below to enable it.
//
//     import "./user_socket.js"

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix"
import { LiveSocket } from "phoenix_live_view"
import { encodeText } from "../vendor/qrcode.js"

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

// ── Board pan / zoom ────────────────────────────────────────────────────────
// The meal cards live inside #board-canvas, which is transformed via CSS custom
// properties (set on :root so LiveView re-renders never strip them). All the
// card/traveller coordinate math converts between screen and canvas space
// through BoardView so dragging stays accurate at any zoom/pan.
const BoardView = {
  scale: 1,
  panX: 0,
  panY: 0,
  MIN: 0.4,
  MAX: 3,
  apply() {
    const root = document.documentElement.style
    root.setProperty("--siano-pan-x", this.panX + "px")
    root.setProperty("--siano-pan-y", this.panY + "px")
    root.setProperty("--siano-scale", String(this.scale))
  },
  // screen point -> canvas coordinates
  toCanvas(clientX, clientY, boardRect) {
    return {
      x: (clientX - boardRect.left - this.panX) / this.scale,
      y: (clientY - boardRect.top - this.panY) / this.scale
    }
  },
  // zoom by `factor` keeping the viewport point (vx, vy) fixed
  zoomAt(vx, vy, factor) {
    const next = Math.min(this.MAX, Math.max(this.MIN, this.scale * factor))
    const f = next / this.scale
    this.panX = vx - (vx - this.panX) * f
    this.panY = vy - (vy - this.panY) * f
    this.scale = next
    this.apply()
  }
}

Hooks.PanZoom = {
  mounted() {
    const surface = this.el
    // start each trip at the default view
    BoardView.scale = 1
    BoardView.panX = 0
    BoardView.panY = 0
    BoardView.apply()
    let two = null
    let one = null // single-finger pan state
    const rect = () => surface.getBoundingClientRect()

    // Interactive bits whose own gesture must win over panning. A single-finger
    // pan may begin anywhere else — empty board OR the blank body of a meal/bill
    // card — but never on one of these.
    const NO_PAN =
      "button, a, input, textarea, select, label, form," +
      ".drag-handle, .field-overlay, .field-label, .traveller-token," +
      "[phx-click], [phx-hook='LongPress']"

    const twoFinger = (e) => {
      const [a, b] = [e.touches[0], e.touches[1]]
      return {
        dist: Math.hypot(b.clientX - a.clientX, b.clientY - a.clientY),
        midX: (a.clientX + b.clientX) / 2,
        midY: (a.clientY + b.clientY) / 2
      }
    }

    surface.addEventListener("touchstart", (e) => {
      if (e.touches.length === 2) {
        two = twoFinger(e)
        one = null
        window.__sianoPanning = true
      } else if (e.touches.length === 1) {
        // Single-finger pan — starts on empty board or on the blank body of a
        // card, but never on an interactive control (its action has priority).
        if (window.__sianoDragging) return
        if (e.target.closest(NO_PAN)) return
        const t = e.touches[0]
        // leave the thin screen-edge zones for the drawer edge-swipe gestures
        if (t.clientX <= 28 || t.clientX >= window.innerWidth - 28) return
        one = { x: t.clientX, y: t.clientY }
      }
    }, { passive: true })

    surface.addEventListener("touchmove", (e) => {
      if (e.touches.length === 2 && two) {
        e.preventDefault()
        const cur = twoFinger(e)
        const r = rect()
        // pinch to zoom around the fingers' midpoint...
        if (two.dist > 0) BoardView.zoomAt(cur.midX - r.left, cur.midY - r.top, cur.dist / two.dist)
        // ...and pan as the midpoint moves
        BoardView.panX += cur.midX - two.midX
        BoardView.panY += cur.midY - two.midY
        BoardView.apply()
        two = cur
      } else if (e.touches.length === 1 && one) {
        e.preventDefault()
        const t = e.touches[0]
        BoardView.panX += t.clientX - one.x
        BoardView.panY += t.clientY - one.y
        one.x = t.clientX
        one.y = t.clientY
        // treat an active board pan as a "drag" so drawer edge-swipes stay quiet
        window.__sianoDragging = true
        BoardView.apply()
      }
    }, { passive: false })

    const endTouch = (e) => {
      if (e.touches.length < 2) {
        two = null
        window.__sianoPanning = false
      }
      if (e.touches.length === 1) {
        // dropped from two fingers to one -> continue as a single-finger pan
        const t = e.touches[0]
        one = { x: t.clientX, y: t.clientY }
      } else if (e.touches.length === 0) {
        one = null
        setTimeout(() => { window.__sianoDragging = false }, 0)
      }
    }
    surface.addEventListener("touchend", endTouch)
    surface.addEventListener("touchcancel", endTouch)

    // Desktop / trackpad: wheel to pan, ctrl+wheel (pinch) to zoom.
    surface.addEventListener("wheel", (e) => {
      e.preventDefault()
      const r = rect()
      if (e.ctrlKey) {
        BoardView.zoomAt(e.clientX - r.left, e.clientY - r.top, Math.exp(-e.deltaY * 0.01))
      } else {
        BoardView.panX -= e.deltaX
        BoardView.panY -= e.deltaY
        BoardView.apply()
      }
    }, { passive: false })
  },
  updated() {
    BoardView.apply()
  }
}

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

// Which traveller is currently "armed" (single-selected in the dock). While a
// traveller is selected, tapping recognised price fields on a bill assigns them
// to that traveller; their custom share becomes the sum of those fields.
// Single-select: selecting one clears the others.
let selectedMember = null
function setSelectedTraveller(id) {
  selectedMember = selectedMember === id ? null : id
  document.querySelectorAll(".traveller-token").forEach((t) => {
    t.classList.toggle("is-selected", t.dataset.memberId === selectedMember)
  })
}

// A traveller token: TAP to arm it for field-assignment (single-select), or
// DRAG onto a meal (add them to the split) / onto empty board (new meal). We
// tell the two apart by movement: below DRAG_THRESH px it's a tap, beyond it a
// drag (at which point the floating ghost appears).
const DRAG_THRESH = 8
Hooks.Traveller = {
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
      el.classList.add("opacity-40")
      const rect = el.getBoundingClientRect()
      ghost = el.cloneNode(true)
      ghost.removeAttribute("id")
      ghost.removeAttribute("phx-hook")
      ghost.classList.remove("is-selected")
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

// A recognised-price label sitting beside its bill field. It can be dragged to
// nudge it clear of the image / other labels. The offset is kept per label
// (photoId:index) in this session-scoped map and re-applied after every
// LiveView re-render (which would otherwise reset the inline transform).
const fieldLabelPos = {}
const FL_TAP = 5 // px of movement below which a press counts as a tap (edit)
Hooks.FieldLabel = {
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
      // a tap (no drag) opens the inline editor to correct the OCR value
      if (!wasDragging) this.enterEdit()
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
    // Drawer open/closed state is server-tracked; read it from the rendered
    // class, and drive it by pushing events (so it survives re-renders).
    const billsOpen = () => el("bills") && !el("bills").classList.contains("-translate-x-full")
    const menuOpen = () => el("menu") && !el("menu").classList.contains("translate-x-full")
    const openBills = () => this.pushEvent("open_drawer", { which: "bills" })
    const openMenu = () => this.pushEvent("open_drawer", { which: "menu" })
    const closeBills = () => this.pushEvent("close_drawer", {})
    const closeMenu = () => this.pushEvent("close_drawer", {})

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

// Render a QR code (as inline SVG) linking to this trip, so others can scan
// instead of copying the URL. Self-contained — works offline / in the PWA.
Hooks.QR = {
  mounted() {
    const url = window.location.origin + "/t/" + this.el.dataset.tripId
    const { size, modules } = encodeText(url, "M")
    const quiet = 4
    const dim = size + quiet * 2
    let path = ""
    for (let r = 0; r < size; r++) {
      for (let c = 0; c < size; c++) {
        if (modules[r][c]) path += `M${c + quiet},${r + quiet}h1v1h-1z`
      }
    }
    this.el.innerHTML =
      `<svg viewBox="0 0 ${dim} ${dim}" width="150" height="150" ` +
      `shape-rendering="crispEdges" xmlns="http://www.w3.org/2000/svg">` +
      `<rect width="${dim}" height="${dim}" fill="#ffffff"/>` +
      `<path d="${path}" fill="#0f172a"/></svg>`
  }
}

// In-page confirmation dialog. Buttons carry data-confirm-event /
// data-confirm-payload / data-confirm-message instead of the native data-confirm
// (whose window.confirm() drops the app out of full-screen). We intercept those
// clicks, show an HTML overlay, and only act on "Yes". Two kinds of action are
// supported: pushing a LiveView event (data-confirm-event), or running a
// client-side callback via the global window.sianoConfirm(message, onYes) —
// used for actions handled purely on the device (e.g. removing a followed trip).
Hooks.Confirm = {
  mounted() {
    const modal = this.el
    const msgEl = modal.querySelector(".confirm-message")
    const yesBtn = modal.querySelector(".confirm-yes")
    const noBtn = modal.querySelector(".confirm-no")
    const backdrop = modal.querySelector(".confirm-backdrop")
    let pending = null // { event, payload } | { fn }

    const open = (message, action) => {
      pending = action
      if (msgEl) msgEl.textContent = message || "Are you sure?"
      modal.classList.remove("hidden")
      requestAnimationFrame(() => modal.classList.remove("opacity-0"))
    }
    const close = () => {
      pending = null
      modal.classList.add("opacity-0")
      setTimeout(() => modal.classList.add("hidden"), 200)
    }

    // programmatic API for client-side confirmations
    window.sianoConfirm = (message, onYes) => open(message, { fn: onYes })

    // intercept clicks on anything requesting confirmation (capture phase, so
    // it runs before other handlers)
    this.onClick = (e) => {
      const trigger = e.target.closest("[data-confirm-event]")
      if (!trigger) return
      e.preventDefault()
      e.stopPropagation()
      let payload = {}
      try {
        payload = JSON.parse(trigger.dataset.confirmPayload || "{}")
      } catch (_) {}
      open(trigger.dataset.confirmMessage, {
        event: trigger.dataset.confirmEvent,
        payload
      })
    }
    document.addEventListener("click", this.onClick, true)

    yesBtn &&
      yesBtn.addEventListener("click", () => {
        const p = pending
        close()
        if (!p) return
        if (typeof p.fn === "function") p.fn()
        else if (p.event) this.pushEvent(p.event, p.payload)
      })
    noBtn && noBtn.addEventListener("click", close)
    backdrop && backdrop.addEventListener("click", close)
  },
  destroyed() {
    document.removeEventListener("click", this.onClick, true)
    if (window.sianoConfirm) delete window.sianoConfirm
  }
}

// Personal-ledger picker, handled entirely on the client (selection stored in
// localStorage per trip). Doing this without a server round-trip means picking
// a participant never re-renders — so the open Settings drawer stays open.
Hooks.Ledger = {
  mounted() {
    this.key = "siano:me:" + this.el.dataset.tripId
    this.el.addEventListener("click", (e) => {
      const btn = e.target.closest(".ledger-pick")
      if (!btn || !this.el.contains(btn)) return
      const id = btn.dataset.memberId
      let cur = null
      try { cur = localStorage.getItem(this.key) } catch (_) {}
      try {
        if (cur === id) localStorage.removeItem(this.key)
        else localStorage.setItem(this.key, id)
      } catch (_) {}
      this.apply()
    })
    this.apply()
  },
  updated() {
    this.apply()
  },
  apply() {
    let sel = null
    try { sel = localStorage.getItem(this.key) } catch (_) {}
    let shown = false
    this.el.querySelectorAll(".ledger-block").forEach((b) => {
      const on = b.dataset.memberId === sel
      b.classList.toggle("hidden", !on)
      if (on) shown = true
    })
    this.el.querySelectorAll(".ledger-pick").forEach((p) => {
      p.classList.toggle("is-me", p.dataset.memberId === sel)
    })
    const empty = this.el.querySelector(".ledger-empty")
    if (empty) empty.classList.toggle("hidden", shown)
  }
}

// A url-safe random trip id, mirroring the server's format (4 random bytes,
// base64url, no padding, lowercased) so client-created trips look the same as
// server-created ones.
function randomTripId() {
  const b = new Uint8Array(4)
  ;(window.crypto || window.msCrypto).getRandomValues(b)
  let s = ""
  for (const x of b) s += String.fromCharCode(x)
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "").toLowerCase()
}

// The trips this user has attended on this device (localStorage), listed in
// Settings so they can switch between them. Every trip you open is remembered
// automatically — no follow step — and a "New trip" is added before navigating.
Hooks.TripSwitcher = {
  key: "siano:trips",
  mounted() {
    this.el.addEventListener("click", (e) => {
      const open = e.target.closest(".trip-open")
      const rm = e.target.closest(".trip-remove")
      if (open && !open.disabled) {
        window.location.href = window.location.origin + "/t/" + open.dataset.id
      } else if (rm) {
        const id = rm.dataset.id
        const name = rm.dataset.name || id
        const doRemove = () => {
          this.save(this.load().filter((t) => t.id !== id))
          this.render()
        }
        if (window.sianoConfirm) {
          window.sianoConfirm(`Remove “${name}” from this device?`, doRemove)
        } else {
          doRemove()
        }
      }
    })

    // "New trip" lives outside this element (Admin section). Create the id on the
    // device and navigate; it gets remembered on arrival like any other trip.
    this.newBtn = document.getElementById("new-trip-btn")
    this.onNew = () => {
      window.location.href = window.location.origin + "/t/" + randomTripId()
    }
    if (this.newBtn) this.newBtn.addEventListener("click", this.onNew)

    this.remember()
    this.render()
  },
  updated() {
    this.remember()
    this.render()
  },
  destroyed() {
    if (this.newBtn && this.onNew) this.newBtn.removeEventListener("click", this.onNew)
  },
  load() {
    try {
      const v = JSON.parse(localStorage.getItem(this.key))
      return Array.isArray(v) ? v.filter((t) => t && t.id) : []
    } catch (_) {
      return []
    }
  },
  save(list) {
    try {
      localStorage.setItem(this.key, JSON.stringify(list))
    } catch (_) {}
  },
  // Remember the current trip: add it if new, otherwise keep its name in sync
  // with any rename. This is what makes every attended trip appear in the list.
  remember() {
    const id = this.el.dataset.tripId
    if (!id) return
    const name = this.el.dataset.tripName || id
    const list = this.load()
    const t = list.find((x) => x.id === id)
    if (t) {
      if (t.name !== name) {
        t.name = name
        this.save(list)
      }
    } else {
      list.unshift({ id, name })
      this.save(list.slice(0, 50))
    }
  },
  render() {
    const id = this.el.dataset.tripId
    const ul = this.el.querySelector(".trip-list")
    if (!ul) return
    ul.replaceChildren()
    const list = this.load()
    if (list.length === 0) {
      const li = document.createElement("li")
      li.className = "text-xs text-slate-500"
      li.textContent = "No trips yet."
      ul.appendChild(li)
      return
    }
    list.forEach((t) => {
      const isCurrent = t.id === id
      const li = document.createElement("li")
      li.className = "flex items-center gap-2 rounded-xl bg-slate-800/60 px-3 py-2"

      const open = document.createElement("button")
      open.type = "button"
      open.className = "trip-open flex min-w-0 flex-1 flex-col text-left"
      open.dataset.id = t.id
      if (isCurrent) open.disabled = true
      const nm = document.createElement("span")
      nm.className = "truncate text-sm font-semibold " + (isCurrent ? "text-amber-300" : "text-slate-100")
      nm.textContent = t.name
      const sub = document.createElement("span")
      sub.className = "truncate text-xs text-slate-500"
      sub.textContent = t.id + (isCurrent ? " · current" : "")
      open.appendChild(nm)
      open.appendChild(sub)
      li.appendChild(open)

      if (!isCurrent) {
        const rm = document.createElement("button")
        rm.type = "button"
        rm.className = "trip-remove shrink-0 text-slate-600 transition hover:text-rose-400"
        rm.dataset.id = t.id
        rm.dataset.name = t.name
        rm.title = "Remove from this device"
        rm.setAttribute("aria-label", "Remove from this device")
        rm.textContent = "✕"
        li.appendChild(rm)
      }

      ul.appendChild(li)
    })
  }
}

// Resize an image file to fit within maxDim (longest side) and return a JPEG
// Blob — so uploads stay small and are stored rescaled.
function resizeImage(file, maxDim, quality) {
  return new Promise((resolve, reject) => {
    const img = new Image()
    const url = URL.createObjectURL(file)
    img.onload = () => {
      URL.revokeObjectURL(url)
      const scale = Math.min(1, maxDim / Math.max(img.width, img.height))
      const w = Math.max(1, Math.round(img.width * scale))
      const h = Math.max(1, Math.round(img.height * scale))
      const canvas = document.createElement("canvas")
      canvas.width = w
      canvas.height = h
      canvas.getContext("2d").drawImage(img, 0, 0, w, h)
      canvas.toBlob((b) => (b ? resolve(b) : reject(new Error("encode failed"))), "image/jpeg", quality)
    }
    img.onerror = () => {
      URL.revokeObjectURL(url)
      reject(new Error("load failed"))
    }
    img.src = url
  })
}

// Add a bill photo: rescale it on the device, then upload to the server, which
// attaches it to the meal (the LiveView re-renders with the new photo window).
Hooks.PhotoUpload = {
  mounted() {
    this.el.addEventListener("change", async () => {
      const file = this.el.files && this.el.files[0]
      if (!file) return
      const label = this.el.closest("label")
      if (label) label.classList.add("opacity-50")
      try {
        const blob = await resizeImage(file, 1280, 0.8)
        const fd = new FormData()
        fd.append("meal_id", this.el.dataset.mealId)
        fd.append("photo", blob, "photo.jpg")
        const token = document.querySelector("meta[name='csrf-token']").getAttribute("content")
        await fetch(`/t/${encodeURIComponent(this.el.dataset.tripId)}/photos`, {
          method: "POST",
          headers: { "x-csrf-token": token },
          body: fd
        })
      } catch (_) {
        // ignore — user can retry
      } finally {
        this.el.value = ""
        if (label) label.classList.remove("opacity-50")
      }
    })
  }
}

// A bill photo. Two jobs:
//   1. Suppress the browser's long-press/right-click image menu (the "save
//      image / open in new tab" callout), which would fight the gesture below.
//   2. Long-press an unrecognised price to add it: crop a zoomed-in region
//      around the finger, send it for a second OCR pass, and the server adds any
//      price it finds (translated back onto the full image).
Hooks.BillPhoto = {
  mounted() {
    const el = this.el
    this.img = el.querySelector("img")

    // no native image menu / callout anywhere on the photo
    this.onCtx = (e) => e.preventDefault()
    el.addEventListener("contextmenu", this.onCtx)

    let timer = null, sx = 0, sy = 0, pid = null

    const clear = () => {
      if (timer) { clearTimeout(timer); timer = null }
      window.removeEventListener("pointermove", onMove)
      window.removeEventListener("pointerup", clear)
      window.removeEventListener("pointercancel", clear)
    }
    const onMove = (e) => {
      if (Math.abs(e.clientX - sx) > 10 || Math.abs(e.clientY - sy) > 10) clear()
    }

    this.onDown = (e) => {
      // let the price overlays / labels handle their own presses
      if (e.target.closest(".field-overlay, .field-label")) return
      if (e.button != null && e.button > 0) return
      sx = e.clientX
      sy = e.clientY
      pid = e.pointerId
      clear()
      timer = setTimeout(() => {
        timer = null
        clear()
        if (navigator.vibrate) try { navigator.vibrate(15) } catch (_) {}
        this.scanAround(sx, sy)
      }, 500)
      window.addEventListener("pointermove", onMove)
      window.addEventListener("pointerup", clear)
      window.addEventListener("pointercancel", clear)
    }
    el.addEventListener("pointerdown", this.onDown)
  },
  destroyed() {
    if (this.onCtx) this.el.removeEventListener("contextmenu", this.onCtx)
    if (this.onDown) this.el.removeEventListener("pointerdown", this.onDown)
  },
  async scanAround(clientX, clientY) {
    const img = this.img
    if (!img || !img.naturalWidth) return
    const r = img.getBoundingClientRect()
    const nx = Math.min(1, Math.max(0, (clientX - r.left) / r.width))
    const ny = Math.min(1, Math.max(0, (clientY - r.top) / r.height))

    // a horizontal-ish window around the tap (prices are short and wide)
    const hw = 0.16, hh = 0.05
    const x0 = Math.max(0, nx - hw), x1 = Math.min(1, nx + hw)
    const y0 = Math.max(0, ny - hh), y1 = Math.min(1, ny + hh)
    const region = { x: x0, y: y0, w: x1 - x0, h: y1 - y0 }

    const nW = img.naturalWidth, nH = img.naturalHeight
    const sw = region.w * nW, sh = region.h * nH
    if (sw < 4 || sh < 4) return
    // upscale the crop so Tesseract has more pixels to work with
    const scale = Math.min(4, Math.max(1, 1000 / sw))
    const canvas = document.createElement("canvas")
    canvas.width = Math.round(sw * scale)
    canvas.height = Math.round(sh * scale)
    const ctx = canvas.getContext("2d")
    ctx.imageSmoothingEnabled = true
    ctx.imageSmoothingQuality = "high"
    ctx.drawImage(img, region.x * nW, region.y * nH, sw, sh, 0, 0, canvas.width, canvas.height)

    const blob = await new Promise((res) => canvas.toBlob(res, "image/jpeg", 0.92))
    if (!blob) return

    this.el.classList.add("is-scanning")
    try {
      const fd = new FormData()
      fd.append("meal_id", this.el.dataset.mealId)
      fd.append("region", JSON.stringify(region))
      fd.append("photo", blob, "crop.jpg")
      const token = document.querySelector("meta[name='csrf-token']").getAttribute("content")
      await fetch(
        `/t/${encodeURIComponent(this.el.dataset.tripId)}/photos/${encodeURIComponent(this.el.dataset.photoId)}/ocr_region`,
        { method: "POST", headers: { "x-csrf-token": token }, body: fd }
      )
    } catch (_) {
      // ignore — user can try again
    } finally {
      this.el.classList.remove("is-scanning")
    }
  }
}

// Render a unix timestamp as "d Mon, HH:MM" in the viewer's local time.
Hooks.LocalTime = {
  mounted() { this.render() },
  updated() { this.render() },
  render() {
    const ts = parseInt(this.el.dataset.ts, 10)
    if (!ts) return
    const d = new Date(ts * 1000)
    const mon = d.toLocaleString(undefined, { month: "short" })
    const hh = String(d.getHours()).padStart(2, "0")
    const mm = String(d.getMinutes()).padStart(2, "0")
    this.el.textContent = `${d.getDate()} ${mon}, ${hh}:${mm}`
  }
}

// Focus (and select) an element as soon as it appears — used for the inline
// "edit share" input so you can type straight away.
Hooks.Focus = {
  mounted() {
    this.el.focus()
    if (typeof this.el.select === "function") this.el.select()
  }
}

// Press-and-hold a participant's name/quota to edit their exact share.
Hooks.LongPress = {
  mounted() {
    const el = this.el
    let timer = null, sx = 0, sy = 0

    const cancel = () => {
      if (timer) { clearTimeout(timer); timer = null }
    }

    el.addEventListener("pointerdown", (e) => {
      sx = e.clientX; sy = e.clientY
      cancel()
      timer = setTimeout(() => {
        timer = null
        // If another share is currently being edited, blur it first so its
        // value is saved (phx-blur) before we open this one. On touch the input
        // keeps focus when you press a non-focusable name, so switching editors
        // would otherwise drop the in-progress edit.
        const active = document.activeElement
        if (active && active.tagName === "INPUT" && (active.id || "").startsWith("share-")) {
          active.blur()
        }
        this.pushEvent("edit_share", {
          meal_id: el.dataset.mealId,
          member_id: el.dataset.memberId
        })
      }, 450)
    })
    // moving too far = a scroll/drag, not a long-press
    el.addEventListener("pointermove", (e) => {
      if (timer && (Math.abs(e.clientX - sx) > 10 || Math.abs(e.clientY - sy) > 10)) cancel()
    })
    el.addEventListener("pointerup", cancel)
    el.addEventListener("pointercancel", cancel)
    el.addEventListener("pointerleave", cancel)
  }
}

// Make the system Back button (Android back, iOS back-swipe) close an open
// drawer and return to the main screen, instead of leaving the app.
//
// When a drawer opens we push a history entry; the next Back pops it and we
// close the drawer. Closing via the UI pops our entry so history stays tidy.
// A MutationObserver watches the drawers' classes so this works no matter how
// they're opened/closed (buttons or swipe gestures).
const DrawerHistory = {
  drawers: new Set(),
  pushed: false,
  programmatic: false,
  closeFromPop: false,
  pushClose: null, // set by the DrawerWatch hook (uses pushEvent)
  closedClass(el) {
    return el.id === "bills" ? "-translate-x-full" : "translate-x-full"
  },
  anyOpen() {
    for (const el of this.drawers) {
      if (!el.classList.contains(this.closedClass(el))) return true
    }
    return false
  },
  // Reacts to the drawer classes (which the server toggles) to keep the history
  // stack in sync: push an entry when a drawer opens, pop it when one closes.
  sync() {
    const open = this.anyOpen()
    if (open && !this.pushed) {
      history.pushState({ sianoDrawer: true }, "")
      this.pushed = true
    } else if (!open && this.pushed) {
      this.pushed = false
      if (this.closeFromPop) {
        this.closeFromPop = false // Back already popped the entry
      } else {
        this.programmatic = true // UI close -> remove our entry
        history.back()
      }
    }
  }
}

window.addEventListener("popstate", () => {
  if (DrawerHistory.programmatic) {
    DrawerHistory.programmatic = false
    return
  }
  if (DrawerHistory.anyOpen() && DrawerHistory.pushClose) {
    // system Back while a drawer is open -> ask the server to close it
    DrawerHistory.closeFromPop = true
    DrawerHistory.pushClose()
  }
})

Hooks.DrawerWatch = {
  mounted() {
    DrawerHistory.drawers.add(this.el)
    DrawerHistory.pushClose = () => this.pushEvent("close_drawer", {})
    if (!DrawerHistory.anyOpen()) DrawerHistory.pushed = false // resync after nav
    this.obs = new MutationObserver(() => DrawerHistory.sync())
    this.obs.observe(this.el, { attributes: true, attributeFilter: ["class"] })
  },
  destroyed() {
    if (this.obs) this.obs.disconnect()
    DrawerHistory.drawers.delete(this.el)
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

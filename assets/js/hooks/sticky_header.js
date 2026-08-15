// Freezes the report drawer's bills-table header row while the table is scrolled.
//
// The report drawer (#report) is the vertical scroll container; the bills table
// sits inside a `div.overflow-x-auto` so a wide traveller matrix can be swiped
// horizontally on a phone. That horizontal wrapper is the catch: per CSS Overflow
// 3, setting `overflow-x: auto` forces `overflow-y` to compute to `auto` too, so
// the wrapper becomes its *own* scroll container. A plain `position: sticky`
// header would then stick to that wrapper — an element that never actually
// scrolls vertically — instead of to the drawer, so it never freezes. CSS alone
// can't pin the header to the top of the drawer while the whole drawer scrolls.
//
// Instead we float a lightweight clone of just the header row, pinned to the top
// of the drawer while the real header is scrolled out of view, mirroring the
// table's own horizontal scroll (so the sticky-left "Bill" column stays put). The
// moment the table's bottom edge reaches the top the clone rides up and out with
// it — revealing the balances / settlements that live below the table, exactly as
// if the header had scrolled away with its rows. The clone is appended to <body>,
// outside LiveView's managed DOM, so morphdom never touches it; we rebuild it on
// every re-render (the board is live — a new bill or traveller changes the table).
export const StickyHeader = {
  mounted() {
    this.scroller = this.el.closest("#report") // vertical scroll container (drawer)
    if (!this.scroller || !this.el.querySelector("table")) return

    // The floating header overlay: pinned to the top of the drawer, clipped to the
    // header's height, and non-interactive. overflow:hidden lets us drive its
    // horizontal offset with scrollLeft (mirroring the table) while clipping
    // everything below the header row.
    this.floater = document.createElement("div")
    this.floater.setAttribute("aria-hidden", "true")
    Object.assign(this.floater.style, {
      position: "fixed",
      overflow: "hidden",
      pointerEvents: "none",
      display: "none",
      top: "0px",
      left: "0px",
      zIndex: "66" // just above the drawer itself (z-[65])
    })
    document.body.appendChild(this.floater)

    this.build() // seed the clone

    this.frame = 0
    this.onScroll = () => {
      if (this.frame) return
      this.frame = requestAnimationFrame(() => {
        this.frame = 0
        this.place()
      })
    }
    // A resize/rotate changes the table's geometry, so re-measure (rebuild).
    this.onResize = () => {
      this.build()
      this.place()
    }

    this.scroller.addEventListener("scroll", this.onScroll, { passive: true })
    this.el.addEventListener("scroll", this.onScroll, { passive: true }) // horizontal
    window.addEventListener("resize", this.onResize)
    // Hide/show when the drawer opens or closes (its state is an attribute on
    // :root — see lib/viewstate.js — and toggling it fires no scroll event).
    this.obs = new MutationObserver(this.onScroll)
    this.obs.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["data-siano-report"]
    })

    this.place()
  },

  // Live board: any viewer's edit re-renders the table (new bill, changed share,
  // a traveller added/removed => a column added/removed). Rebuild the clone so its
  // columns and names stay in step, then re-place it.
  updated() {
    this.build()
    this.place()
  },

  destroyed() {
    if (this.frame) cancelAnimationFrame(this.frame)
    if (this.scroller) this.scroller.removeEventListener("scroll", this.onScroll)
    this.el.removeEventListener("scroll", this.onScroll)
    window.removeEventListener("resize", this.onResize)
    if (this.obs) this.obs.disconnect()
    if (this.floater) this.floater.remove()
  },

  // (Re)build the clone shown in the floater: a copy of just the <thead>, wrapped
  // in a table that reuses the real one's classes but with a fixed layout so we
  // can pin each column to its measured width. Strip ids/phx-hook attributes so
  // the copy can never collide with the live DOM or spin up phantom hooks. Column
  // widths and the drawer's safe-area padding are measured here (they only change
  // on a re-render or resize, both of which call build()).
  build() {
    const table = this.el.querySelector("table")
    this.realThead = table && table.querySelector("thead")
    if (!this.realThead) return

    const clone = document.createElement("table")
    clone.className = table.className
    clone.style.tableLayout = "fixed"
    clone.style.margin = "0"

    const thead = this.realThead.cloneNode(true)
    thead.querySelectorAll("[id]").forEach((n) => n.removeAttribute("id"))
    thead.querySelectorAll("[phx-hook]").forEach((n) => n.removeAttribute("phx-hook"))
    clone.appendChild(thead)
    this.floater.replaceChildren(clone)

    // Pin each cloned header cell to the width its real counterpart renders at
    // (which is the full column width), so the frozen row lines up with the rows
    // beneath it. Read all widths first, then write, to avoid layout thrash.
    const realCells = [...this.realThead.querySelectorAll("th")]
    const cloneCells = [...thead.querySelectorAll("th")]
    const widths = realCells.map((c) => c.getBoundingClientRect().width)
    let total = 0
    widths.forEach((w, i) => {
      total += w
      if (cloneCells[i]) cloneCells[i].style.width = w + "px"
    })
    clone.style.width = total + "px"

    // The drawer's top padding honours the safe-area inset; the header should
    // freeze at the top of the *content*, below any notch.
    this.padTop = parseFloat(getComputedStyle(this.scroller).paddingTop) || 0
  },

  // Position (or hide) the floating header for the current scroll offset.
  place() {
    // Publish the horizontal scroll offset so the first-column fade tracks it
    // (see .report-bill-cell in app.css). On :root so both the in-table cells
    // *and* the body-level header clone inherit it. At scrollLeft 0 (scrolled
    // fully right) the fade is off and the whole title shows; scrolling left
    // reveals the spending through the tail of the title.
    document.documentElement.style.setProperty("--report-fade", this.el.scrollLeft + "px")

    const open = document.documentElement.hasAttribute("data-siano-report")
    const table = this.el.querySelector("table")
    if (!open || !this.realThead || !table) return this.hide()

    const pin = this.scroller.getBoundingClientRect().top + (this.padTop || 0)
    const tbl = table.getBoundingClientRect()
    const wrap = this.el.getBoundingClientRect()
    const headH = this.realThead.getBoundingClientRect().height

    // Freeze only while the real header has scrolled above the pin line and the
    // table is still on screen. In the final headH the clone rides up with the
    // table's bottom edge, so it leaves exactly as the table scrolls away —
    // uncovering whatever sits below the table in the drawer.
    if (tbl.top >= pin || tbl.bottom <= pin) return this.hide()

    Object.assign(this.floater.style, {
      display: "block",
      top: Math.min(pin, tbl.bottom - headH) + "px",
      left: wrap.left + "px",
      width: wrap.width + "px",
      height: headH + "px"
    })
    this.floater.scrollLeft = this.el.scrollLeft // mirror the table's horizontal scroll
  },

  hide() {
    if (this.floater && this.floater.style.display !== "none") {
      this.floater.style.display = "none"
    }
  }
}

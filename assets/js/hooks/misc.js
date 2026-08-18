// Render a unix timestamp as "d Mon, HH:MM" in the viewer's local time.
export const LocalTime = {
  mounted() { this.render() },
  updated() { this.render() },
  render() {
    const ts = parseInt(this.el.dataset.ts, 10)
    if (!ts) return
    const d = new Date(ts * 1000)
    // force English month abbreviation regardless of the device locale
    const mon = d.toLocaleString("en-US", { month: "short" })
    const hh = String(d.getHours()).padStart(2, "0")
    const mm = String(d.getMinutes()).padStart(2, "0")
    this.el.textContent = `${d.getDate()} ${mon}, ${hh}:${mm}`
  }
}

// The report CSV download link.
//
// The download is a plain browser navigation, so the server can't see the
// phone's time zone on its own. At *click* time this hook rewrites the URL with:
//
//  • `tz_offset` — the browser's current UTC offset (Date.getTimezoneOffset(),
//    minutes) — and `tz` — the IANA zone name. The server timestamps the
//    downloaded *filename* and every time inside the CSV in this local
//    wall-clock (not UTC, nor the phone's home zone — matters on a trip abroad).
//    The filename must come from the server because a `Content-Disposition:
//    filename` overrides the `<a download>` attribute, so setting `download`
//    client-side has no effect in Chrome/Firefox.
//  • `_` — a per-click cache-buster, so every save is a distinct URL. Without it
//    the browser reused the previous download (same URL) and handed back the
//    *previous* file — pinning a stale timestamp and prompting "…report (6).csv"
//    style overwrites. A distinct URL forces a fresh fetch → fresh timestamp.
export const ReportLink = {
  mounted() {
    this.base = stripQuery(this.el.getAttribute("href"))
    this.el.addEventListener("click", () => {
      const search = new URLSearchParams()
      // getTimezoneOffset(): minutes of (UTC − local), e.g. -120 for UTC+2.
      search.set("tz_offset", String(new Date().getTimezoneOffset()))
      try {
        const tz = Intl.DateTimeFormat().resolvedOptions().timeZone
        if (tz) search.set("tz", tz)
      } catch (_) { /* Intl unavailable — offset alone is enough */ }
      search.set("_", String(Date.now()))
      // Set synchronously before the default navigation runs, keeping it
      // root-relative so it works behind any host/proxy.
      this.el.setAttribute("href", `${this.base}?${search.toString()}`)
    })
  },
  // morphdom resets href to the clean server value on re-render (e.g. trip
  // switch) — re-capture it so the next click rebuilds from the right base.
  updated() { this.base = stripQuery(this.el.getAttribute("href")) }
}

function stripQuery(href) {
  if (!href) return href
  const q = href.indexOf("?")
  return q === -1 ? href : href.slice(0, q)
}

// Focus (and select) an element as soon as it appears — used for the inline
// "edit share" input so you can type straight away.
export const Focus = {
  mounted() {
    this.el.focus()
    if (typeof this.el.select === "function") this.el.select()
  }
}

import { setArmedAmount, clearArmedAmount } from "../lib/amount.js"

// The meal card's "Total" input. While it is focused for writing, tapping a
// recognised price field on the bill photo writes that price into the total
// (handled in MealCard / FieldLabel) — one more way to set the meal total.
export const AmountField = {
  mounted() {
    const mealId = this.el.dataset.mealId
    this.el.addEventListener("focus", () => setArmedAmount(mealId, this.el))
    this.el.addEventListener("blur", () => {
      // Delay clearing: tapping a bill-photo field blurs this input first, and
      // the field-tap handler must still see the armed state to redirect the tap
      // into the total. It consumes (clears) the state itself once used; this is
      // just the fallback for a plain blur (tapping elsewhere).
      setTimeout(() => clearArmedAmount(mealId), 300)
    })
  }
}

import { setSelectedTraveller } from "../lib/selection.js"

// A participant chip in a meal card. Press-and-HOLD the name/quota to edit their
// exact share; a short TAP arms that traveller in the dock — the same as tapping
// their token at the bottom, so partial costs can be assigned from either place.
export const LongPress = {
  mounted() {
    const el = this.el
    let timer = null, sx = 0, sy = 0, moved = false

    const cancel = () => {
      if (timer) { clearTimeout(timer); timer = null }
    }

    el.addEventListener("pointerdown", (e) => {
      sx = e.clientX; sy = e.clientY
      moved = false
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
    // moving too far = a scroll/drag, not a long-press (and not a tap)
    el.addEventListener("pointermove", (e) => {
      if (Math.abs(e.clientX - sx) > 10 || Math.abs(e.clientY - sy) > 10) { moved = true; cancel() }
    })
    // A short tap that neither fired the long-press (timer still pending) nor
    // scrolled away arms this traveller in the dock.
    el.addEventListener("pointerup", () => {
      const wasTap = timer !== null && !moved
      cancel()
      if (wasTap) setSelectedTraveller(el.dataset.memberId)
    })
    el.addEventListener("pointercancel", cancel)
    el.addEventListener("pointerleave", cancel)
  }
}


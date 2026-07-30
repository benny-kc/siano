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

// Focus (and select) an element as soon as it appears — used for the inline
// "edit share" input so you can type straight away.
export const Focus = {
  mounted() {
    this.el.focus()
    if (typeof this.el.select === "function") this.el.select()
  }
}

// Press-and-hold a participant's name/quota to edit their exact share.
export const LongPress = {
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


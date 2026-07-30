import { encodeText } from "../../vendor/qrcode.js"

// Render a QR code (as inline SVG) linking to this trip, so others can scan
// instead of copying the URL. Self-contained — works offline / in the PWA.
export const QR = {
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
export const Confirm = {
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


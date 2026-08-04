// Personal-ledger picker, handled entirely on the client (selection stored in
// localStorage per trip). Doing this without a server round-trip means picking
// a participant never re-renders — so the open Settings drawer stays open.
export const Ledger = {
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

// Copy text to the clipboard, falling back to a hidden <textarea> +
// execCommand for older browsers / non-secure contexts where the async
// Clipboard API isn't available. Returns a Promise so callers can toast on
// success and quietly ignore failure.
function copyText(text) {
  if (navigator.clipboard && navigator.clipboard.writeText) {
    return navigator.clipboard.writeText(text)
  }
  return new Promise((resolve, reject) => {
    try {
      const ta = document.createElement("textarea")
      ta.value = text
      ta.setAttribute("readonly", "")
      ta.style.position = "fixed"
      ta.style.top = "-1000px"
      ta.style.opacity = "0"
      document.body.appendChild(ta)
      ta.focus()
      ta.select()
      const ok = document.execCommand("copy")
      document.body.removeChild(ta)
      ok ? resolve() : reject(new Error("copy failed"))
    } catch (e) {
      reject(e)
    }
  })
}

// A small transient toast ("monit") that fades itself out after a timeout.
// Lives on document.body — outside anything LiveView manages — so morphdom
// re-renders never touch it. Reused across calls (one node), and the timer is
// reset each time so rapid taps don't leave it stuck.
function sianoToast(message) {
  let t = document.getElementById("siano-toast")
  if (!t) {
    t = document.createElement("div")
    t.id = "siano-toast"
    t.className = "siano-toast"
    t.setAttribute("role", "status")
    t.setAttribute("aria-live", "polite")
    document.body.appendChild(t)
  }
  t.textContent = message
  // Restart the fade-in animation even if the toast is already showing.
  t.classList.remove("is-visible")
  void t.offsetWidth
  t.classList.add("is-visible")
  clearTimeout(t._sianoTimer)
  t._sianoTimer = setTimeout(() => t.classList.remove("is-visible"), 3000)
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
export const TripSwitcher = {
  key: "siano:trips",
  mounted() {
    this.el.addEventListener("click", (e) => {
      const open = e.target.closest(".trip-open")
      const share = e.target.closest(".trip-share")
      const rm = e.target.closest(".trip-remove")
      if (share) {
        const url = window.location.origin + "/t/" + share.dataset.id
        copyText(url)
          .then(() =>
            sianoToast("🔗 Link copied — share it with your colleagues in a message.")
          )
          .catch(() => sianoToast("Couldn't copy — the link is: " + url))
      } else if (open && !open.disabled) {
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

      // Share: copy the trip link to the clipboard (available for every trip,
      // including the current one). A plain monochrome glyph kept as muted as
      // the remove button, in a fixed-width column so the icons line up.
      const sh = document.createElement("button")
      sh.type = "button"
      sh.className = "trip-share w-5 shrink-0 text-center text-slate-600 transition hover:text-amber-300"
      sh.dataset.id = t.id
      sh.title = "Copy link to share"
      sh.setAttribute("aria-label", "Copy link to share")
      sh.textContent = "⧉"
      li.appendChild(sh)

      if (!isCurrent) {
        const rm = document.createElement("button")
        rm.type = "button"
        rm.className = "trip-remove ml-2 w-5 shrink-0 text-center text-slate-600 transition hover:text-rose-400"
        rm.dataset.id = t.id
        rm.dataset.name = t.name
        rm.title = "Remove from this device"
        rm.setAttribute("aria-label", "Remove from this device")
        rm.textContent = "✕"
        li.appendChild(rm)
      } else {
        // No remove button on the current trip — reserve its slot (same width
        // and left gap) so every share icon stays in the same column.
        const spacer = document.createElement("span")
        spacer.className = "ml-2 w-5 shrink-0"
        spacer.setAttribute("aria-hidden", "true")
        li.appendChild(spacer)
      }

      ul.appendChild(li)
    })
  }
}


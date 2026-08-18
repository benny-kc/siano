// "Add Siano to your home screen" hint.
//
// A subtle, one-time banner that offers to install the PWA — sibling in spirit
// to the first-run gesture coach marks (hooks/hints.js): purely a per-viewer
// nicety, entirely client-side, its visibility a data-attribute on :root
// (`data-siano-install`) so a morphdom re-render can never blink it away, and
// remembered once dismissed/installed in localStorage (`siano:install`).
//
// There is no cross-browser "add to home screen" API, so this has two flavours,
// chosen at runtime:
//
//   • Chrome / Edge / other Chromium (Android + desktop) fire a
//     `beforeinstallprompt` event we can defer and replay from a tap — a REAL
//     one-tap install. We capture that event as early as possible in app.js
//     (it can fire before this hook mounts) onto `window.__sianoInstallPrompt`
//     and re-broadcast it as `siano:installable`; the banner then shows an
//     "Add" button wired to `deferred.prompt()`.
//
//   • iOS/iPadOS Safari has NO such API — the user must use the system Share
//     sheet themselves. So there we can only show the instruction ("tap Share,
//     then Add to Home Screen"); there is no Add button to wire.
//
// Everyone else (already installed / running standalone, Firefox, in-app
// WebViews, Chrome-on-iOS which also can't add to the home screen) gets
// nothing — the banner simply never arms.

const STORE = "siano:install"
const ROOT = document.documentElement

function dismissed() {
  try {
    return localStorage.getItem(STORE) === "1"
  } catch (_) {
    return false
  }
}
function remember() {
  try {
    localStorage.setItem(STORE, "1")
  } catch (_) {}
}
function forget() {
  try {
    localStorage.removeItem(STORE)
  } catch (_) {}
}

// Already launched from the home screen? Then there is nothing to offer.
function isStandalone() {
  return (
    window.matchMedia("(display-mode: standalone)").matches ||
    window.matchMedia("(display-mode: fullscreen)").matches ||
    window.matchMedia("(display-mode: minimal-ui)").matches ||
    window.navigator.standalone === true
  )
}

// iOS/iPadOS Safari specifically — the only iOS browser whose Share sheet has
// "Add to Home Screen". iPadOS 13+ masquerades as desktop Safari (MacIntel with
// a touch screen), so sniff that too; and exclude the other iOS browsers
// (Chrome/Firefox/Edge/Opera) which can't add to the home screen at all.
function isIosSafari() {
  const ua = navigator.userAgent || ""
  const iOS =
    /iP(hone|ad|od)/.test(ua) ||
    (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1)
  const nonSafari = /(CriOS|FxiOS|EdgiOS|OPiOS|GSA)/.test(ua)
  return iOS && /WebKit/.test(ua) && !nonSafari
}

export const InstallHint = {
  mounted() {
    // Chrome/Edge: the install event may already have fired before we mounted.
    this.onInstallable = () => this.offerChrome()
    window.addEventListener("siano:installable", this.onInstallable)

    // Chrome fires this once the app is actually installed — retire quietly.
    this.onInstalled = () => this.retire()
    window.addEventListener("appinstalled", this.onInstalled)

    // "Show the tips again" (Settings) clears the coach-mark memory and fires
    // this; re-offer the install banner along with them.
    this.onReset = () => {
      forget()
      this.arm()
    }
    window.addEventListener("siano:hints-reset", this.onReset)

    // Banner buttons (delegated within this.el).
    this.onClick = (e) => {
      if (e.target.closest("[data-install-add]")) return this.install()
      if (e.target.closest("[data-install-dismiss]")) return this.retire()
    }
    this.el.addEventListener("click", this.onClick)

    this.arm()
  },

  // Decide what (if anything) to offer this viewer.
  arm() {
    if (isStandalone() || dismissed()) return
    if (window.__sianoInstallPrompt) return this.offerChrome()
    if (isIosSafari()) {
      // Let the board settle before sliding the hint in — same courtesy the
      // gesture coach marks extend.
      clearTimeout(this.iosTimer)
      this.iosTimer = setTimeout(() => {
        if (!isStandalone() && !dismissed() && !ROOT.hasAttribute("data-siano-install")) {
          ROOT.setAttribute("data-siano-install", "ios")
        }
      }, 1800)
    }
    // Otherwise wait — a `siano:installable` event may still arrive (Chromium),
    // or nothing will and the banner simply never shows.
  },

  offerChrome() {
    if (isStandalone() || dismissed()) return
    if (ROOT.getAttribute("data-siano-install") === "chrome") return
    ROOT.setAttribute("data-siano-install", "chrome")
  },

  async install() {
    const deferred = window.__sianoInstallPrompt
    if (!deferred) return this.retire() // lost it somehow — just close
    deferred.prompt()
    try {
      await deferred.userChoice
    } catch (_) {}
    window.__sianoInstallPrompt = null // a captured prompt is single-use
    this.retire()
  },

  // Dismissed or installed: remember it so we never nag again, and hide.
  retire() {
    remember()
    ROOT.removeAttribute("data-siano-install")
  },

  destroyed() {
    clearTimeout(this.iosTimer)
    window.removeEventListener("siano:installable", this.onInstallable)
    window.removeEventListener("appinstalled", this.onInstalled)
    window.removeEventListener("siano:hints-reset", this.onReset)
    if (this.onClick) this.el.removeEventListener("click", this.onClick)
  }
}

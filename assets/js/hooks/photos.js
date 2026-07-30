import { NetMeter } from "../lib/net.js"
import { mealZOrder } from "../lib/zorder.js"

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

// Drop a live placeholder "photo" into a meal's slot so the wait between tapping
// the camera and the picture appearing is visible. Returns a small controller:
//   setPhase(text)          — indeterminate step (spinner + caption)
//   setProgress(pct, speed) — the real upload step (bar + % + KB/s)
//   remove()                — take it down
function showPhotoPlaceholder(mealId) {
  const noop = { setProgress() {}, indeterminate() {}, remove() {} }
  const slot = document.getElementById(`photo-ph-${mealId}`)
  if (!slot) return noop
  const ph = document.createElement("div")
  ph.className = "photo-placeholder animate-pop"
  // just a loading progress bar; the speed now lives in the header meters
  ph.innerHTML = `<div class="ph-box"><div class="ph-bar indeterminate"><div class="ph-fill"></div></div></div>`
  slot.appendChild(ph)
  const bar = ph.querySelector(".ph-bar")
  const fill = ph.querySelector(".ph-fill")
  return {
    indeterminate() {
      bar.classList.add("indeterminate")
      fill.style.width = ""
    },
    setProgress(pct) {
      bar.classList.remove("indeterminate")
      fill.style.width = Math.round(pct * 100) + "%"
    },
    remove() {
      ph.remove()
    }
  }
}

// POST a photo via XHR (not fetch) so we get real upload progress; the bytes
// sent feed the global NetMeter (fetch is wrapped, but XHR is not).
function xhrUpload(url, fd, token, onProgress) {
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest()
    xhr.open("POST", url)
    xhr.setRequestHeader("x-csrf-token", token)
    let lastLoaded = 0
    xhr.upload.onprogress = (e) => {
      NetMeter.up += Math.max(0, e.loaded - lastLoaded)
      lastLoaded = e.loaded
      if (e.lengthComputable) onProgress(e.loaded / e.total)
    }
    xhr.onload = () =>
      xhr.status >= 200 && xhr.status < 300 ? resolve(xhr) : reject(new Error("http " + xhr.status))
    xhr.onerror = () => reject(new Error("network"))
    xhr.send(fd)
  })
}

// Rescale and upload a bill photo to a meal (shared by the per-card camera and
// the top-bar camera). The photo is sent exactly ONCE: the server picks the
// best of the four 90° rotations and stores it upright (see Siano.Images), so
// the client no longer round-trips rotated copies to detect the orientation.
// The placeholder shows real upload progress during the transfer, then sits
// indeterminate while the server straightens + attaches the photo (the POST
// only resolves once the upright image is stored, so the board renders it
// upright straight away). The header meters show the transfer speed.
async function uploadBillPhoto(tripId, mealId, file) {
  const ph = showPhotoPlaceholder(mealId)
  try {
    const blob = await resizeImage(file, 1280, 0.8)
    const fd = new FormData()
    fd.append("meal_id", mealId)
    fd.append("photo", blob, "photo.jpg")
    const token = document.querySelector("meta[name='csrf-token']").getAttribute("content")
    await xhrUpload(`/t/${encodeURIComponent(tripId)}/photos`, fd, token, (pct) => ph.setProgress(pct))
    // the photo is stored (and rendered) by now; let the bar fade out shortly after
    ph.indeterminate()
    setTimeout(() => ph.remove(), 500)
  } catch (_) {
    setTimeout(() => ph.remove(), 400)
  }
}

// Per-card camera: add a photo to this meal.
export const PhotoUpload = {
  mounted() {
    this.el.addEventListener("change", async () => {
      const file = this.el.files && this.el.files[0]
      if (!file) return
      const label = this.el.closest("label")
      if (label) label.classList.add("opacity-50")
      try {
        await uploadBillPhoto(this.el.dataset.tripId, this.el.dataset.mealId, file)
      } catch (_) {
        // ignore — user can retry
      } finally {
        this.el.value = ""
        if (label) label.classList.remove("opacity-50")
      }
    })
  }
}

// Top-bar camera: add a photo to the meal the user last interacted with, or —
// if the board is empty — to a brand new meal the server creates for us. The
// file dialog opens on the label tap (a user gesture); the meal is resolved via
// a server round-trip and then the photo is uploaded.
export const TopPhoto = {
  mounted() {
    this.el.addEventListener("change", () => {
      const file = this.el.files && this.el.files[0]
      this.el.value = ""
      if (!file) return
      const tripId = this.el.dataset.tripId

      // most recently touched card = highest stacking value
      let target = null, best = -1
      document.querySelectorAll(".meal-card").forEach((c) => {
        const z = mealZOrder[c.dataset.mealId] || parseInt(c.style.zIndex || "0", 10) || 0
        if (z >= best) { best = z; target = c.dataset.mealId }
      })

      const label = this.el.closest("label")
      if (label) label.classList.add("opacity-50")
      this.pushEvent("photo_target", { meal_id: target || "" }, (reply) => {
        const done = () => label && label.classList.remove("opacity-50")
        if (reply && reply.meal_id) {
          uploadBillPhoto(tripId, reply.meal_id, file).catch(() => {}).finally(done)
        } else {
          done()
        }
      })
    })
  }
}

// A bill photo. Two jobs:
//   1. Suppress the browser's long-press/right-click image menu (the "save
//      image / open in new tab" callout), which would fight the gesture below.
//   2. Long-press an unrecognised price to add it: crop a zoomed-in region
//      around the finger, send it for a second OCR pass, and the server adds any
//      price it finds (translated back onto the full image).
export const BillPhoto = {
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
      // labels manage their own presses (tap = edit/assign, drag = move)
      if (e.target.closest(".field-label")) return
      if (e.button != null && e.button > 0) return
      // long-press on a price border re-scans THAT field to improve it; on empty
      // image it adds a missed field.
      const overlay = e.target.closest(".field-overlay")
      const index = overlay ? parseInt(overlay.dataset.index, 10) : null
      sx = e.clientX
      sy = e.clientY
      pid = e.pointerId
      clear()
      timer = setTimeout(() => {
        timer = null
        clear()
        if (navigator.vibrate) try { navigator.vibrate(15) } catch (_) {}
        this.suppressNextClick() // don't let the release also assign the field
        if (overlay) {
          const b = overlay.getBoundingClientRect()
          this.scanAround((b.left + b.right) / 2, (b.top + b.bottom) / 2, index)
        } else {
          this.scanAround(sx, sy, null)
        }
      }, 500)
      window.addEventListener("pointermove", onMove)
      window.addEventListener("pointerup", clear)
      window.addEventListener("pointercancel", clear)
    }
    el.addEventListener("pointerdown", this.onDown)
  },
  // Swallow the click that fires right after a long-press so it doesn't also
  // trigger the field's tap action (assign to selected traveller).
  suppressNextClick() {
    const stop = (e) => {
      e.stopPropagation()
      e.preventDefault()
      cleanup()
    }
    const cleanup = () => {
      document.removeEventListener("click", stop, true)
      clearTimeout(t)
    }
    const t = setTimeout(cleanup, 700)
    document.addEventListener("click", stop, true)
  },
  destroyed() {
    if (this.onCtx) this.el.removeEventListener("contextmenu", this.onCtx)
    if (this.onDown) this.el.removeEventListener("pointerdown", this.onDown)
  },
  async scanAround(clientX, clientY, replaceIndex = null) {
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
      if (replaceIndex != null) fd.append("replace", String(replaceIndex))
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


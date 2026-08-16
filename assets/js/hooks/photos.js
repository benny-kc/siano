import { NetMeter } from "../lib/net.js"
import { mealZOrder } from "../lib/zorder.js"
import { hasNativeCamera, captureBillPhoto } from "../lib/native.js"

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

// ── Uploader-only local preview ─────────────────────────────────────────────
// The device that uploads a bill already holds the image bytes, so it shows its
// OWN copy instead of downloading the stored (rotated) image back from the
// server. That turns the uploader's downlink for the photo into just the chosen
// rotation angle (a couple of bytes in the POST response) instead of ~200 KB of
// JPEG — and the photo appears instantly, before any server round-trip.
//
// It only applies to the uploader, in this session: other viewers of the same
// trip never had the bytes, and this device loses the in-memory blob on reload,
// so both fall back to the server URL the <img> is rendered with. The map is
// keyed by photo id, which the client generates UP FRONT and sends with the
// upload, so the mapping exists before the server-broadcast <img> mounts —
// otherwise the browser would fetch the server URL first and the saving is lost.
const localPhotos = {} // photoId -> object URL (a blob: URL of the local image)

// A URL-safe random id, same shape as the server's Photos.gen_id/0.
function genPhotoId() {
  const bytes = crypto.getRandomValues(new Uint8Array(9))
  let s = ""
  for (const n of bytes) s += String.fromCharCode(n)
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

// Rotate a JPEG Blob by 0/90/180/270° clockwise (matching ImageMagick's
// -rotate) and return a new Blob. Used only to orient the uploader's local
// preview to the angle the server chose, so the price overlays line up.
function rotateBlob(blob, deg) {
  if (!deg) return Promise.resolve(blob)
  return new Promise((resolve, reject) => {
    const img = new Image()
    const url = URL.createObjectURL(blob)
    img.onload = () => {
      URL.revokeObjectURL(url)
      const swap = deg === 90 || deg === 270
      const w = img.width, h = img.height
      const canvas = document.createElement("canvas")
      canvas.width = swap ? h : w
      canvas.height = swap ? w : h
      const ctx = canvas.getContext("2d")
      ctx.translate(canvas.width / 2, canvas.height / 2)
      ctx.rotate((deg * Math.PI) / 180)
      ctx.drawImage(img, -w / 2, -h / 2)
      canvas.toBlob((b) => (b ? resolve(b) : reject(new Error("encode failed"))), "image/jpeg", 0.85)
    }
    img.onerror = () => {
      URL.revokeObjectURL(url)
      reject(new Error("load failed"))
    }
    img.src = url
  })
}

// Point a photo's <img> at the uploader's local copy, if we have one. Called
// from the BillPhoto hook on mount and after every re-render — morphdom resets
// the src back to the server URL, so it must be re-applied (the usual gotcha).
function applyLocalPhoto(container) {
  const url = localPhotos[container.dataset.photoId]
  if (!url) return
  const img = container.querySelector("img.bill-img")
  if (img && img.getAttribute("src") !== url) img.setAttribute("src", url)
}

// Register (or replace) the local preview for a photo id and apply it if the
// image is already on screen. Revokes the previous blob URL to avoid leaks.
function setLocalPhoto(id, url) {
  const prev = localPhotos[id]
  localPhotos[id] = url
  if (prev && prev !== url) URL.revokeObjectURL(prev)
  const container = document.getElementById(`photo-${id}`)
  if (container) applyLocalPhoto(container)
}

function dropLocalPhoto(id) {
  const url = localPhotos[id]
  if (url) URL.revokeObjectURL(url)
  delete localPhotos[id]
}

// Rescale and upload a bill photo to a meal (shared by the per-card camera and
// the top-bar camera). The photo is sent exactly ONCE: the server picks the
// best of the four 90° rotations and stores it upright (see Siano.Images), so
// the client no longer round-trips rotated copies to detect the orientation.
// The client also generates the photo id and shows its own local copy (see
// localPhotos above), so it never downloads the stored image back. The
// placeholder shows real upload progress, then sits indeterminate while the
// server straightens + attaches the photo. The header meters show the speed.
async function uploadBillPhoto(tripId, mealId, file) {
  const ph = showPhotoPlaceholder(mealId)
  const photoId = genPhotoId()
  try {
    const blob = await resizeImage(file, 1280, 0.8)
    // Register the local preview (un-rotated) up front, so when the server
    // broadcasts the new photo its <img> shows this device's own copy instead
    // of fetching the stored image.
    setLocalPhoto(photoId, URL.createObjectURL(blob))

    const fd = new FormData()
    fd.append("meal_id", mealId)
    fd.append("photo_id", photoId)
    fd.append("photo", blob, "photo.jpg")
    const token = document.querySelector("meta[name='csrf-token']").getAttribute("content")
    const xhr = await xhrUpload(`/t/${encodeURIComponent(tripId)}/photos`, fd, token, (pct) => ph.setProgress(pct))

    // Rotate the local preview to the angle the server stored the bill at, so
    // this device matches the shared image (and the recognised-price overlays).
    let angle = 0
    try { angle = (JSON.parse(xhr.responseText) || {}).angle || 0 } catch (_) {}
    if (angle) setLocalPhoto(photoId, URL.createObjectURL(await rotateBlob(blob, angle)))

    ph.indeterminate()
    setTimeout(() => ph.remove(), 500)
  } catch (_) {
    // upload failed — no photo was attached, so drop the dangling local preview
    dropLocalPhoto(photoId)
    setTimeout(() => ph.remove(), 400)
  }
}

// Native capture straight into a known meal (per-card camera). Mirrors the file
// <input>'s label-dimming; a cancelled capture (null file) is a no-op.
async function captureIntoMeal(inputEl, tripId, mealId) {
  const label = inputEl.closest("label")
  if (label) label.classList.add("opacity-50")
  try {
    const file = await captureBillPhoto()
    if (file) await uploadBillPhoto(tripId, mealId, file)
  } catch (_) {
    // ignore — user can retry
  } finally {
    if (label) label.classList.remove("opacity-50")
  }
}

// Per-card camera: add a photo to this meal.
export const PhotoUpload = {
  mounted() {
    // Native shell: capture through the OS camera plugin instead of the WebView
    // file picker (better permissions + capture UX). Intercept the tap so the
    // `<input type=file>` dialog never opens. Falls back to the input path in a
    // plain browser, or a native shell without the Camera plugin. See NATIVE.md.
    if (hasNativeCamera()) {
      this.onNativeTap = (e) => {
        e.preventDefault()
        captureIntoMeal(this.el, this.el.dataset.tripId, this.el.dataset.mealId)
      }
      this.el.addEventListener("click", this.onNativeTap)
    }

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
  },
  destroyed() {
    if (this.onNativeTap) this.el.removeEventListener("click", this.onNativeTap)
  }
}

// The most recently touched card = highest stacking value. Returns its meal id,
// or "" when the board is empty (the server then makes a fresh meal).
function topPhotoTargetMeal() {
  let target = null, best = -1
  document.querySelectorAll(".meal-card").forEach((c) => {
    const z = mealZOrder[c.dataset.mealId] || parseInt(c.style.zIndex || "0", 10) || 0
    if (z >= best) { best = z; target = c.dataset.mealId }
  })
  return target || ""
}

// Resolve the target meal on the server (it may create one) and upload `file`.
function uploadToResolvedMeal(hook, tripId, file) {
  const label = hook.el.closest("label")
  if (label) label.classList.add("opacity-50")
  hook.pushEvent("photo_target", { meal_id: topPhotoTargetMeal() }, (reply) => {
    const done = () => label && label.classList.remove("opacity-50")
    if (reply && reply.meal_id) {
      uploadBillPhoto(tripId, reply.meal_id, file).catch(() => {}).finally(done)
    } else {
      done()
    }
  })
}

// Top-bar camera: add a photo to the meal the user last interacted with, or —
// if the board is empty — to a brand new meal the server creates for us. The
// file dialog opens on the label tap (a user gesture); the meal is resolved via
// a server round-trip and then the photo is uploaded.
export const TopPhoto = {
  mounted() {
    // Native shell: capture via the OS camera, then resolve the meal + upload.
    // Both must happen from the tap (a user gesture), so capture first. Falls
    // back to the `<input type=file>` path otherwise. See NATIVE.md.
    if (hasNativeCamera()) {
      this.onNativeTap = async (e) => {
        e.preventDefault()
        let file = null
        try {
          file = await captureBillPhoto()
        } catch (_) {
          // ignore — user can retry
        }
        if (file) uploadToResolvedMeal(this, this.el.dataset.tripId, file)
      }
      this.el.addEventListener("click", this.onNativeTap)
    }

    this.el.addEventListener("change", () => {
      const file = this.el.files && this.el.files[0]
      this.el.value = ""
      if (!file) return
      uploadToResolvedMeal(this, this.el.dataset.tripId, file)
    })
  },
  destroyed() {
    if (this.onNativeTap) this.el.removeEventListener("click", this.onNativeTap)
  }
}

// A bill photo. Three jobs:
//   1. If this device uploaded the photo, show its own local copy instead of
//      downloading the stored image back (see localPhotos); re-applied on every
//      re-render because morphdom resets the <img> src to the server URL.
//   2. Suppress the browser's long-press/right-click image menu (the "save
//      image / open in new tab" callout), which would fight the gesture below.
//   3. Long-press an unrecognised price to add it: crop a zoomed-in region
//      around the finger, send it for a second OCR pass, and the server adds any
//      price it finds (translated back onto the full image).
export const BillPhoto = {
  mounted() {
    const el = this.el
    this.img = el.querySelector("img")

    // show the uploader's local copy if we have one (no server download)
    applyLocalPhoto(el)

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
  // morphdom reconciles the <img> src back to the server URL on every re-render,
  // so re-point it at the uploader's local copy afterwards (no-op for viewers
  // that don't have one).
  updated() {
    applyLocalPhoto(this.el)
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


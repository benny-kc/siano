// Native-shell (Capacitor) integration — see NATIVE.md.
//
// Siano can ship to iOS/Android as a thin Capacitor shell whose WebView loads
// this same server-rendered app. Capacitor injects `window.Capacitor` and, when
// a plugin is installed natively, exposes it to JS at runtime — so we reach the
// camera through those globals rather than importing `@capacitor/camera`. That
// keeps this web bundle a plain PWA with no Capacitor build dependency; every
// function here simply no-ops in a normal browser (where `window.Capacitor` is
// absent), so the existing web paths are untouched.

// Running inside a Capacitor native shell (not a plain browser tab)?
export function isNativeShell() {
  const C = window.Capacitor
  return !!(C && typeof C.isNativePlatform === "function" && C.isNativePlatform())
}

// Is the native Camera plugin actually installed and callable? Only then do the
// photo hooks take over capture; otherwise the normal `<input type=file>` path
// stays in place as the fallback (e.g. a shell that didn't add the plugin).
export function hasNativeCamera() {
  const C = window.Capacitor
  return (
    isNativeShell() &&
    typeof C.isPluginAvailable === "function" &&
    C.isPluginAvailable("Camera")
  )
}

// The Camera plugin proxy, via whichever bridge API this Capacitor version
// exposes. `hasNativeCamera()` should gate calls to this.
function cameraPlugin() {
  const C = window.Capacitor
  if (!C) return null
  if (C.Plugins && C.Plugins.Camera) return C.Plugins.Camera
  if (typeof C.registerPlugin === "function") return C.registerPlugin("Camera")
  return null
}

// Capture (or pick) a bill photo through the OS camera and return it as a File,
// ready to hand straight to uploadBillPhoto() (which resizes + uploads it just
// like a browser-picked file, and POSTs to the same /t/:id/photos endpoint — so
// no server change is needed). Returns null when the user cancels.
export async function captureBillPhoto() {
  const Camera = cameraPlugin()
  if (!Camera) return null

  let photo
  try {
    photo = await Camera.getPhoto({
      resultType: "uri", // webPath is a fetch()-able URL inside the WebView
      source: "PROMPT", // let the user choose Camera or Photo Library
      quality: 85,
      correctOrientation: true,
      presentationStyle: "fullscreen"
    })
  } catch (e) {
    if (isCancel(e)) return null // user backed out — not an error
    throw e
  }

  const src = photo && (photo.webPath || photo.path)
  if (!src) return null
  const blob = await (await fetch(src)).blob()
  return new File([blob], "photo.jpg", { type: blob.type || "image/jpeg" })
}

// The Camera plugin rejects with a "cancel"-ish message when the user backs out;
// treat that as "no photo", not a failure.
function isCancel(e) {
  const msg = String((e && (e.message || e.errorMessage)) || "").toLowerCase()
  return msg.includes("cancel")
}

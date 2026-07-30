// ── Network activity meter ──────────────────────────────────────────────────
// A rough, whole-app byte counter so the header can show live up/down speed —
// useful for telling "the app is slow" from "the connection is slow". It counts
// the LiveView WebSocket (the bulk of traffic) in both directions, HTTP request
// bodies for uplink, and every HTTP response (images, JS, fetch/XHR) for
// downlink via the Resource Timing API. Approximate, not exact — a gauge.
export const NetMeter = { up: 0, down: 0 }

function netBytes(d) {
  if (d == null) return 0
  if (typeof d === "string") return d.length
  if (typeof d.byteLength === "number") return d.byteLength
  if (typeof d.size === "number") return d.size
  return 0
}
function netBodySize(body) {
  if (!body) return 0
  const b = netBytes(body)
  if (b) return b
  if (typeof FormData !== "undefined" && body instanceof FormData) {
    let s = 0
    for (const [, v] of body.entries()) s += netBytes(v) || (typeof v === "string" ? v.length : 0)
    return s
  }
  return 0
}

// Must run before the LiveView socket is created so its WebSocket is wrapped.
;(function installNetMeter() {
  const OrigWS = window.WebSocket
  if (OrigWS) {
    const origSend = OrigWS.prototype.send
    OrigWS.prototype.send = function (data) {
      NetMeter.up += netBytes(data)
      return origSend.call(this, data)
    }
    try {
      window.WebSocket = new Proxy(OrigWS, {
        construct(target, args) {
          const ws = new target(...args)
          ws.addEventListener("message", (e) => { NetMeter.down += netBytes(e.data) })
          return ws
        }
      })
    } catch (_) {}
  }

  const origFetch = window.fetch
  if (origFetch) {
    // responses are counted by the resource observer; here we add the uplink
    window.fetch = function (input, init) {
      NetMeter.up += netBodySize(init && init.body)
      return origFetch.call(this, input, init)
    }
  }

  if (typeof PerformanceObserver !== "undefined") {
    try {
      new PerformanceObserver((list) => {
        for (const e of list.getEntries()) NetMeter.down += e.transferSize || 0
      }).observe({ type: "resource", buffered: false })
    } catch (_) {}
  }
})()


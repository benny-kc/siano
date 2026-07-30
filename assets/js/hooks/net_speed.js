import { NetMeter } from "../lib/net.js"

// Header speedometers. Samples NetMeter periodically to show up/down rate. Idle
// (< 1 KB/s) reads dark; active reads amber. Lives in a phx-update=ignore slot
// so re-renders don't wipe the values.
function netFmt(bps) {
  if (bps >= 1024 * 1024) return (bps / (1024 * 1024)).toFixed(1) + "M"
  if (bps >= 1024) return Math.round(bps / 1024) + "k"
  return "0"
}
export const NetSpeed = {
  mounted() {
    const upEl = this.el.querySelector(".net-up")
    const downEl = this.el.querySelector(".net-down")
    let lastUp = NetMeter.up
    let lastDown = NetMeter.down
    let lastT = performance.now()
    const paint = (el, arrow, bps) => {
      if (!el) return
      el.textContent = arrow + " " + netFmt(bps)
      el.classList.toggle("is-active", bps >= 1024)
    }
    this.timer = setInterval(() => {
      const now = performance.now()
      const dt = (now - lastT) / 1000
      const up = dt > 0 ? (NetMeter.up - lastUp) / dt : 0
      const down = dt > 0 ? (NetMeter.down - lastDown) / dt : 0
      lastUp = NetMeter.up
      lastDown = NetMeter.down
      lastT = now
      paint(upEl, "↑", up)
      paint(downEl, "↓", down)
    }, 900)
  },
  destroyed() {
    clearInterval(this.timer)
  }
}


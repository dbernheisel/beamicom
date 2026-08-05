// On-screen NES controller (inlined controller.svg): map SVG element ids to NES
// buttons; pointer down/up presses/releases via the server (same path as keys).
// Pointer events unify mouse + touch; capture guarantees the matching "up" so
// buttons can't stick. The pressed highlight is driven by the server-owned held
// set, delivered on the container's data-held attribute (keyboard + click alike).
const SVG_BUTTONS = {
  path3729: "up", path3731: "down", path2950: "left", path3727: "right",
  path12005: "a", path12001: "b", rect3789: "select", rect3791: "start",
}

export default {
  mounted() {
    this.byButton = {}
    for (const [id, button] of Object.entries(SVG_BUTTONS)) {
      const el = this.el.querySelector("#" + id)
      if (!el) continue

      ;(this.byButton[button] ||= []).push(el)
      el.style.cursor = "pointer"
      el.style.pointerEvents = "all" // fire even on stroked/unfilled shapes
      el.addEventListener("pointerdown", e => {
        e.preventDefault()
        try { el.setPointerCapture(e.pointerId) } catch (_) {}
        this.pushEvent("button_down", {button})
      })
      const release = () => this.pushEvent("button_up", {button})
      el.addEventListener("pointerup", release)
      el.addEventListener("pointercancel", release)
    }
    this.applyHeld()
  },
  updated() { this.applyHeld() },
  applyHeld() {
    const held = new Set((this.el.dataset.held || "").split(" ").filter(Boolean))
    for (const [button, els] of Object.entries(this.byButton)) {
      els.forEach(el => el.classList.toggle("is-pressed", held.has(button)))
    }
  },
}

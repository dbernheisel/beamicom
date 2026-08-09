// On-screen NES controller plus browser Gamepad API support. Pointer events unify
// mouse + touch; physical USB/Bluetooth gamepads are polled once per animation
// frame because the browser API does not emit individual button events.
const SVG_BUTTONS = {
  path3729: "up", path3731: "down", path2950: "left", path3727: "right",
  path12005: "a", path12001: "b", rect3789: "select", rect3791: "start",
}

const DEAD_ZONE = 0.5

function pressed(gamepad, index) {
  const button = gamepad.buttons[index]
  return Boolean(button && (button.pressed || button.value >= 0.5))
}

function physicalButtons(gamepad) {
  if (!gamepad) return []

  const buttons = new Set()
  const horizontal = gamepad.axes[0] || 0
  const vertical = gamepad.axes[1] || 0

  if (pressed(gamepad, 12) || vertical < -DEAD_ZONE) buttons.add("up")
  if (pressed(gamepad, 13) || vertical > DEAD_ZONE) buttons.add("down")
  if (pressed(gamepad, 14) || horizontal < -DEAD_ZONE) buttons.add("left")
  if (pressed(gamepad, 15) || horizontal > DEAD_ZONE) buttons.add("right")
  if (pressed(gamepad, 0)) buttons.add("a")
  if (pressed(gamepad, 1)) buttons.add("b")
  if (pressed(gamepad, 8)) buttons.add("select")
  if (pressed(gamepad, 9)) buttons.add("start")

  return [...buttons].sort()
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
        window.dispatchEvent(new CustomEvent("beamicom:button", {
          detail: {source: "pointer", button, down: true},
        }))
        this.pushEvent("button_down", {button})
      })
      const release = () => {
        window.dispatchEvent(new CustomEvent("beamicom:button", {
          detail: {source: "pointer", button, down: false},
        }))
        this.pushEvent("button_up", {button})
      }
      el.addEventListener("pointerup", release)
      el.addEventListener("pointercancel", release)
    }

    this.lastPhysicalState = ""
    this.pollPhysicalGamepad = () => {
      const gamepads = navigator.getGamepads ? navigator.getGamepads() : []
      const gamepad = Array.from(gamepads).find(Boolean)
      const buttons = physicalButtons(gamepad)
      const state = buttons.join(" ")

      if (state !== this.lastPhysicalState) {
        this.lastPhysicalState = state
        window.dispatchEvent(new CustomEvent("beamicom:gamepad-state", {
          detail: {buttons},
        }))
        this.pushEvent("gamepad_buttons", {buttons})
      }

      this.gamepadFrame = requestAnimationFrame(this.pollPhysicalGamepad)
    }
    this.gamepadFrame = requestAnimationFrame(this.pollPhysicalGamepad)
    this.applyHeld()
  },
  destroyed() {
    cancelAnimationFrame(this.gamepadFrame)
  },
  updated() { this.applyHeld() },
  applyHeld() {
    const held = new Set((this.el.dataset.held || "").split(" ").filter(Boolean))
    for (const [button, els] of Object.entries(this.byButton)) {
      els.forEach(el => el.classList.toggle("is-pressed", held.has(button)))
    }
  },
}

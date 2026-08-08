import {Socket} from "phoenix"

// Stop arrow keys / space from scrolling the page while playing. In client
// mode this hook also owns a standard Phoenix Channel connected directly to
// the server-mode node and sends the complete held-button set on each change.
const gameKeys = new Set(["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", " "])
const keyButtons = {
  arrowup: "up", arrowdown: "down", arrowleft: "left", arrowright: "right",
  x: "a", z: "b", enter: "start", shift: "select",
}

export default {
  mounted() {
    this.held = new Set()
    this.controllerUrl = this.el.dataset.controllerUrl

    if (this.controllerUrl) {
      this.controllerSocket = new Socket(this.controllerUrl)
      this.controllerSocket.connect()
      this.controllerChannel = this.controllerSocket.channel("controller:1", {})
      this.controllerChannel.join()
        .receive("ok", () => this.sendButtons())
        .receive("error", response => console.error("controller channel rejected", response))
    }

    this.setButton = (button, down) => {
      if (!button) return
      down ? this.held.add(button) : this.held.delete(button)
      this.sendButtons()
    }

    this.sendButtons = () => {
      if (this.controllerChannel) {
        this.controllerChannel.push("buttons", {buttons: [...this.held]})
      }
    }

    // Send keydown from JS (not phx-window-keydown) so we can drop the OS
    // auto-repeat: e.repeat is true while a key is held, and the emulator already
    // has it latched. Still preventDefault repeats so the page doesn't scroll.
    // keyup stays on phx-window-keyup — it never repeats.
    this.handler = e => {
      if (gameKeys.has(e.key)) e.preventDefault()
      if (e.repeat) return
      this.setButton(keyButtons[e.key.toLowerCase()], true)
      this.pushEvent("keydown", {key: e.key})
    }
    window.addEventListener("keydown", this.handler)

    this.keyup = e => this.setButton(keyButtons[e.key.toLowerCase()], false)
    window.addEventListener("keyup", this.keyup)

    this.gamepad = e => this.setButton(e.detail.button, e.detail.down)
    window.addEventListener("beamicom:button", this.gamepad)

    // The Live.Player <video> ships with `controls`, so when it has focus it
    // swallows game keys (Enter/Space/arrows) for media shortcuts instead of
    // letting them bubble to phx-window-keydown. Strip `controls` and make it
    // unfocusable so every key reaches the emulator input handler. Poll until the
    // player has rendered the video.
    const readyVideo = () => {
      const v = document.getElementById("videoPlayer")
      if (!v) return false
      v.removeAttribute("controls")
      v.tabIndex = -1
      return true
    }

    if (!readyVideo()) {
      this.videoTimer = setInterval(() => readyVideo() && clearInterval(this.videoTimer), 200)
    }

    // Browsers block audible autoplay, so the stream starts muted. Unmute on the
    // first user gesture (a keypress to play counts). Retries until the video exists.
    this.unmute = () => {
      const v = document.getElementById("videoPlayer")
      if (v) {
        v.muted = false
        v.volume = 1
        window.removeEventListener("keydown", this.unmute)
        window.removeEventListener("pointerdown", this.unmute)
      }
    }
    window.addEventListener("keydown", this.unmute)
    window.addEventListener("pointerdown", this.unmute)
  },
  destroyed() {
    clearInterval(this.videoTimer)
    this.held.clear()
    this.sendButtons()
    if (this.controllerChannel) this.controllerChannel.leave()
    if (this.controllerSocket) this.controllerSocket.disconnect()
    window.removeEventListener("keydown", this.handler)
    window.removeEventListener("keyup", this.keyup)
    window.removeEventListener("beamicom:button", this.gamepad)
    window.removeEventListener("keydown", this.unmute)
    window.removeEventListener("pointerdown", this.unmute)
  },
}

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
    this.heldBySource = {
      keyboard: new Set(),
      pointer: new Set(),
      physical: new Set(),
    }
    this.controllerUrl = this.el.dataset.controllerUrl
    this.notificationSound = new Audio("/sounds/you-are-playing.wav")
    this.notificationSound.preload = "auto"
    this.lastNotificationSoundAt = Number.NEGATIVE_INFINITY
    this.playNotificationSound = () => {
      const now = performance.now()
      if (now - this.lastNotificationSoundAt < 750) return

      this.lastNotificationSoundAt = now
      this.notificationSound.currentTime = 0
      const playback = this.notificationSound.play()
      if (playback) playback.catch(() => {})
    }
    this.setControllerStatus = message => {
      const status = document.getElementById("player-status")
      const notification = document.getElementById("player-notification")
      if (!status || !notification || !message) return

      status.textContent = message
      clearTimeout(this.controllerStatusTimer)
      cancelAnimationFrame(this.controllerStatusFrame)
      notification.classList.remove("is-visible")

      this.controllerStatusFrame = requestAnimationFrame(() => {
        notification.classList.add("is-visible")
        this.playNotificationSound()
        this.controllerStatusTimer = setTimeout(() => {
          notification.classList.remove("is-visible")
        }, 4000)
      })
    }
    this.handleEvent("player_notification_sound", () => this.playNotificationSound())

    if (this.controllerUrl) {
      this.controllerSocket = new Socket(this.controllerUrl)
      this.controllerSocket.connect()
      this.controllerChannel = this.controllerSocket.channel("controller:lobby", {})
      this.controllerChannel.join()
        .receive("ok", response => {
          this.setControllerStatus(response.message)
          if (response.player) this.sendButtons()
        })
        .receive("error", response => console.error("controller channel rejected", response))

      this.controllerChannel.on("announcement", response => {
        this.setControllerStatus(response.message)
      })
      this.controllerChannel.on("player_assignment", response => {
        this.setControllerStatus(response.message)
        this.sendButtons()
      })
      this.controllerChannel.on("queue_position", response => {
        this.setControllerStatus(response.message)
      })
    }

    this.setButton = (source, button, down) => {
      if (!button) return
      const held = this.heldBySource[source]
      down ? held.add(button) : held.delete(button)
      this.sendButtons()
    }

    this.sendButtons = () => {
      if (this.controllerChannel) {
        const held = new Set(Object.values(this.heldBySource).flatMap(set => [...set]))
        this.controllerChannel.push("buttons", {buttons: [...held]})
      }
    }

    // Send keydown from JS (not phx-window-keydown) so we can drop the OS
    // auto-repeat: e.repeat is true while a key is held, and the emulator already
    // has it latched. Still preventDefault repeats so the page doesn't scroll.
    // keyup stays on phx-window-keyup — it never repeats.
    this.handler = e => {
      if (gameKeys.has(e.key)) e.preventDefault()
      if (e.repeat) return
      this.setButton("keyboard", keyButtons[e.key.toLowerCase()], true)
      this.pushEvent("keydown", {key: e.key})
    }
    window.addEventListener("keydown", this.handler)

    this.keyup = e => this.setButton("keyboard", keyButtons[e.key.toLowerCase()], false)
    window.addEventListener("keyup", this.keyup)

    this.pointer = e => this.setButton("pointer", e.detail.button, e.detail.down)
    window.addEventListener("beamicom:button", this.pointer)

    this.physicalGamepad = e => {
      this.heldBySource.physical = new Set(e.detail.buttons || [])
      this.sendButtons()
    }
    window.addEventListener("beamicom:gamepad-state", this.physicalGamepad)

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
    clearTimeout(this.controllerStatusTimer)
    cancelAnimationFrame(this.controllerStatusFrame)
    this.notificationSound.pause()
    Object.values(this.heldBySource).forEach(held => held.clear())
    this.sendButtons()
    if (this.controllerChannel) this.controllerChannel.leave()
    if (this.controllerSocket) this.controllerSocket.disconnect()
    window.removeEventListener("keydown", this.handler)
    window.removeEventListener("keyup", this.keyup)
    window.removeEventListener("beamicom:button", this.pointer)
    window.removeEventListener("beamicom:gamepad-state", this.physicalGamepad)
    window.removeEventListener("keydown", this.unmute)
    window.removeEventListener("pointerdown", this.unmute)
  },
}

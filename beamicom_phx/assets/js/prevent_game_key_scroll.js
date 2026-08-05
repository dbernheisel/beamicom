// Stop arrow keys / space from scrolling the page while playing; the keydown
// still reaches the server via phx-window-keydown.
const gameKeys = new Set(["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", " "])

export default {
  mounted() {
    // Send keydown from JS (not phx-window-keydown) so we can drop the OS
    // auto-repeat: e.repeat is true while a key is held, and the emulator already
    // has it latched. Still preventDefault repeats so the page doesn't scroll.
    // keyup stays on phx-window-keyup — it never repeats.
    this.handler = e => {
      if (gameKeys.has(e.key)) e.preventDefault()
      if (e.repeat) return
      this.pushEvent("keydown", {key: e.key})
    }
    window.addEventListener("keydown", this.handler)

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
    window.removeEventListener("keydown", this.handler)
    window.removeEventListener("keydown", this.unmute)
    window.removeEventListener("pointerdown", this.unmute)
  },
}

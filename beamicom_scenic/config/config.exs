import Config

# Scenic already ships Nx and EXLA, and the SNES core needs its accelerated
# Mode 1/7 renderer to keep the 32 kHz audio stream fed in realtime. This only
# changes the renderer default when the core is hosted by this application;
# the standalone SNES package remains native-first.
config :beamicom_snes, ppu_renderer: :nx

# Opt the NES and Game Boy render boundaries into their Nx implementations at compile
# time. Keep this environment variable set for every Mix invocation so Mix's
# compile-env validation sees the same configuration at build and launch.
if System.get_env("BEAMICOM_SCENIC_NX") in ["1", "true", "yes", "on"] do
  config :beamicom_nes,
    ppu_renderer: Beamicom.NES.Nx.PPURenderer,
    apu_renderer: Beamicom.NES.Nx.APUBlockRenderer

  config :beamicom_gbc,
    ppu_renderer: Beamicom.GB.Nx.PPURenderer,
    apu_renderer: Beamicom.GB.Nx.APUSynthRenderer
end

# Static asset library (fonts/images) — needed by Scenic text/button components.
config :scenic, :assets, module: Beamicom.Scenic.Assets

# Long-lived Scenic viewport. Replaceable emulator sessions are rendered by a
# child component without recreating the root scene or native window.
# The local driver needs native GLFW — see the README.
config :beamicom_scenic, :viewport,
  name: :beamicom_viewport,
  size: {960, 800},
  default_scene: Beamicom.Scenic.Shell,
  drivers: [
    [
      module: Scenic.Driver.Local,
      # The driver's default is 29 ms, which caps streamed bitmap updates at
      # roughly 34 FPS. The output hub and driver busy flag already coalesce
      # frames, so request each new NES frame without an extra timer throttle.
      limit_ms: 0,
      # Window dimensions drive Shell layout directly. Driver-level scaling
      # would interpolate the complete viewport between integer stages.
      position: [scaled: false, centered: false],
      window: [title: "beamicom", resizeable: true],
      # The local driver's custom-callback validator and dispatcher disagree on
      # the callback tuple format in 0.11. Stop the viewport through its supported
      # option; Host monitors it, tears down emulation, and then stops the BEAM.
      on_close: :stop_viewport
    ]
  ]

import Config

# Opt the NES and Game Boy render boundaries into their EXLA implementations at compile
# time. Keep this environment variable set for every Mix invocation so Mix's
# compile-env validation sees the same configuration at build and launch.
if System.get_env("BEAMICOM_SCENIC_NX") in ["1", "true", "yes", "on"] do
  config :beamicom_nes,
    ppu_renderer: Beamicom.NES.Nx.PPURenderer,
    apu_renderer: Beamicom.NES.Nx.APUBlockRenderer

  config :beamicom_gbc,
    ppu_renderer: Beamicom.GB.Nx.PPURenderer,
    apu_renderer: Beamicom.GB.Nx.APUBlockRenderer
end

# Static asset library (fonts/images) — needed by Scenic text/button components.
config :scenic, :assets, module: Beamicom.Scenic.Assets

# Scenic viewport for local verification. The core-specific size and default
# scene are filled in by `Beamicom.Scenic.play/2`.
# The local driver needs native GLFW — see the README.
config :beamicom_scenic, :viewport,
  name: :beamicom_viewport,
  default_scene: Beamicom.Scenic.Screen,
  drivers: [
    [
      module: Scenic.Driver.Local,
      position: [scaled: true, centered: true],
      window: [title: "beamicom", resizeable: true],
      on_close: :stop_system
    ]
  ]

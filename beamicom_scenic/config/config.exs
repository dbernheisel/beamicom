import Config

# Static asset library (fonts/images) — needed by Scenic text/button components.
config :scenic, :assets, module: Beamicom.NES.Scenic.Assets

# Scenic viewport for local verification (spec §7). The size and default scene
# are filled in by `Beamicom.NES.Scenic.play/2` (scaled to the requested integer factor).
# The local driver needs native GLFW — see the README.
config :beamicom_scenic, :viewport,
  name: :beamicom_viewport,
  default_scene: Beamicom.NES.Scenic.Screen,
  drivers: [
    [
      module: Scenic.Driver.Local,
      window: [title: "beamicom", resizeable: false],
      on_close: :stop_system
    ]
  ]

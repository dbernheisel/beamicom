import Config

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
      window: [title: "beamicom", resizeable: false],
      on_close: :stop_system
    ]
  ]

import Config

# These values are consumed with Application.compile_env/3 while the core
# dependency is compiled. A machine therefore has no application-environment
# lookup when choosing its rendering implementation.
config :beamicom_gbc,
  ppu_renderer: Beamicom.GB.Nx.PPURenderer,
  apu_renderer: Beamicom.GB.Nx.APUBlockRenderer,
  # Cross-backend tests deliberately swap renderers on one APU instance. Normal
  # builds compile the hot capture functions directly for the selected backend.
  allow_runtime_renderers: config_env() == :test

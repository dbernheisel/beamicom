import Config

if System.get_env("BEAMICOM_NX") in ["1", "true", "yes", "on"] do
  config :beamicom_gba,
    ppu_renderer: Beamicom.GBA.Nx.PPURenderer,
    allow_runtime_renderers: config_env() == :test
end

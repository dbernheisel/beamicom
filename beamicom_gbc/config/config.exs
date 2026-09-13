import Config

# The standalone Nx regression suite opts into the optional renderer modules.
# Consumer applications select the same modules in their own compile-time config.
if System.get_env("BEAMICOM_NX") in ["1", "true", "yes", "on"] do
  config :beamicom_gbc,
    ppu_renderer: Beamicom.GB.Nx.PPURenderer,
    apu_renderer: Beamicom.GB.Nx.APUBlockRenderer,
    allow_runtime_renderers: config_env() == :test
end

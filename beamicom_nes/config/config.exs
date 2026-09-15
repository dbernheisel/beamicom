import Config

# The standalone Nx regression suite opts into the optional renderer modules.
# Consumer applications select the same modules in their own compile-time config.
if System.get_env("BEAMICOM_NX") in ["1", "true", "yes", "on"] do
  apu_renderer =
    if System.get_env("BEAMICOM_AUDIO_48") in ["1", "true", "yes", "on"],
      do: Beamicom.NES.Nx.FrameAPURenderer,
      else: Beamicom.NES.Nx.APUBlockRenderer

  config :beamicom_nes,
    ppu_renderer: Beamicom.NES.Nx.PPURenderer,
    apu_renderer: apu_renderer
end

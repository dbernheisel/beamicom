import Config

# Compile the optional package's core dependency directly against the Nx
# frame renderers. The dependency-free beamicom_nes build retains :native.
config :beamicom_nes,
  ppu_renderer: Beamicom.NES.Nx.PPURenderer,
  apu_renderer: Beamicom.NES.Nx.APUBlockRenderer

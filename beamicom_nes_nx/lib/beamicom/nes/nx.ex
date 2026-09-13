defmodule Beamicom.NES.Nx do
  @moduledoc """
  Activates the optional Nx renderers for the NES core.

  Starting the `:beamicom_nes_nx` application enables the atlas PPU renderer
  and block APU renderer. Set `config :beamicom_nes_nx, auto_enable: false` to
  load the package without changing the native renderer defaults, then call
  `enable/1` when needed.
  """

  @default_ppu Beamicom.NES.Nx.PPUAtlasRenderer
  @default_apu Beamicom.NES.Nx.APUBlockRenderer

  @doc "Installs the Nx-backed PPU and APU renderers in the NES core."
  def enable(opts \\ []) do
    ppu_renderer = Keyword.get(opts, :ppu_renderer, @default_ppu)
    apu_renderer = Keyword.get(opts, :apu_renderer, @default_apu)

    Application.put_env(:beamicom_nes, :ppu_renderer, ppu_renderer)
    Application.put_env(:beamicom_nes, :apu_renderer, apu_renderer)
    :ok
  end

  @doc "Restores the dependency-free native PPU and APU renderers."
  def disable do
    Application.put_env(:beamicom_nes, :ppu_renderer, :native)
    Application.put_env(:beamicom_nes, :apu_renderer, :native)
    :ok
  end
end

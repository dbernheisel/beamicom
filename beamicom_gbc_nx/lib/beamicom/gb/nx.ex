defmodule Beamicom.GB.Nx do
  @moduledoc """
  Activates optional Nx renderers for the Game Boy core.

  Call `enable/1` before loading a machine to select its renderers. Set
  `config :beamicom_gbc_nx, auto_enable: true` when a client should opt in at
  application startup.
  """

  @doc "Installs the frame-wide PPU and block APU renderers."
  def enable(opts \\ []) do
    ppu_renderer = Keyword.get(opts, :ppu_renderer, Beamicom.GB.Nx.PPURenderer)
    apu_renderer = Keyword.get(opts, :apu_renderer, Beamicom.GB.Nx.APUBlockRenderer)
    Application.put_env(:beamicom_gbc, :ppu_renderer, ppu_renderer)
    Application.put_env(:beamicom_gbc, :apu_renderer, apu_renderer)
    :ok
  end

  @doc "Restores native Game Boy scanline composition."
  def disable do
    Application.put_env(:beamicom_gbc, :ppu_renderer, :native)
    Application.put_env(:beamicom_gbc, :apu_renderer, :native)
    :ok
  end
end

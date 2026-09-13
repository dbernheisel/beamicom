defmodule Beamicom.NES.Nx do
  @moduledoc """
  Compile-time Nx renderer selection for the NES core.

  This package configures `:beamicom_nes` while its dependency is compiled.
  Renderer selection is fixed for the build and does not require application
  environment lookups during emulation.
  """

  @ppu_renderer Application.compile_env(:beamicom_nes, :ppu_renderer, :native)
  @apu_renderer Application.compile_env(:beamicom_nes, :apu_renderer, :native)

  @doc "Returns the renderer modules selected when the NES core was compiled."
  def backends, do: %{ppu: @ppu_renderer, apu: @apu_renderer}
end

defmodule Beamicom.GB.Nx do
  @moduledoc """
  Compile-time Nx renderer selection for the Game Boy core.

  This package configures `:beamicom_gbc` while its dependency is compiled.
  Renderer selection is therefore fixed for the build and is never read from
  the application environment while an emulator is running.
  """

  @ppu_renderer Application.compile_env(:beamicom_gbc, :ppu_renderer, :native)
  @apu_renderer Application.compile_env(:beamicom_gbc, :apu_renderer, :native)

  @doc "Returns the renderer modules selected when the Game Boy core was compiled."
  def backends, do: %{ppu: @ppu_renderer, apu: @apu_renderer}
end

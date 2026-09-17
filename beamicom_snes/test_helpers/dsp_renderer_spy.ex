if Code.ensure_loaded?(Beamicom.SNES.Nx.DSPRenderer) do
  defmodule Beamicom.SNES.DSPRendererSpy do
    @moduledoc false

    alias Beamicom.SNES.Nx.DSPRenderer

    def minimum_frames, do: 1
    def synthesis_minimum_frames, do: 1

    def render(rows, mixer) do
      send(self(), {:dsp_renderer_spy, :mix, length(rows)})
      DSPRenderer.render(rows, mixer)
    end

    def render(voices, end_flags, ram, mixer, frames) do
      send(self(), {:dsp_renderer_spy, :synthesis, frames})
      DSPRenderer.render(voices, end_flags, ram, mixer, frames)
    end

    def render_echo(voices, end_flags, ram, mixer, frames, echo_state, registers) do
      send(self(), {:dsp_renderer_spy, :echo, frames})
      DSPRenderer.render_echo(voices, end_flags, ram, mixer, frames, echo_state, registers)
    end
  end
end

if Code.ensure_loaded?(Nx.Defn) and Code.ensure_loaded?(EXLA) do
  defmodule Beamicom.NES.Nx do
    @moduledoc """
    Nx renderer selection and runtime video options for the NES core.

    A consuming application can configure the default renderers while
    `:beamicom_nes` is compiled, or select the Blargg NTSC renderer per console
    at load time.
    """

    @ppu_renderer Application.compile_env(:beamicom_nes, :ppu_renderer, :native)
    @apu_renderer Application.compile_env(:beamicom_nes, :apu_renderer, :native)

    @doc "Returns the renderer modules selected when the NES core was compiled."
    def backends, do: %{ppu: @ppu_renderer, apu: @apu_renderer}

    @doc """
    Build `Beamicom.NES.System.load/2` options for an Nx-rendered NTSC frame.

        Beamicom.NES.System.load(media, Beamicom.NES.Nx.video_options(:composite))

    The standard presets are `:composite`, `:svideo`, `:rgb`, and `:monochrome`.
    """
    def video_options(preset \\ :composite, options \\ []) do
      renderer_options = Keyword.put(options, :preset, preset)
      [ppu_renderer: {Beamicom.NES.Nx.BlarggNTSC.Renderer, renderer_options}]
    end

    @doc "Return NES capabilities adjusted for a runtime Blargg NTSC renderer."
    def video_capabilities(preset \\ :composite, options \\ []) do
      Beamicom.NES.System.capabilities(video_options(preset, options))
    end
  end
end

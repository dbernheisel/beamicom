if Code.ensure_loaded?(Nx.Defn) do
  defmodule Beamicom.SNES.Nx do
    @moduledoc "Nx acceleration and runtime video-filter options for the SNES core."

    def compile(function, args) do
      Nx.Defn.compile(function, Enum.map(args, &Nx.to_template/1), compiler_options())
    end

    def backend, do: Nx.Defn.to_backend(compiler_options())

    def compiler_options do
      case Nx.Defn.default_options() do
        [] -> fallback_compiler_options()
        options -> options
      end
    end

    @doc """
    Build SNES load options for a runtime Blargg NTSC presentation filter.

    The standard presets are `:composite`, `:svideo`, `:rgb`, and `:monochrome`.
    """
    def video_options(preset \\ :composite, options \\ []) do
      filter_options = Keyword.put(options, :preset, preset)
      [video_filter: {Beamicom.SNES.Nx.BlarggNTSC, filter_options}]
    end

    @doc "Return SNES presentation capabilities for a Blargg NTSC preset."
    def video_capabilities(preset \\ :composite, options \\ []) do
      Beamicom.SNES.PPU.video_capabilities(video_options(preset, options))
    end

    defp fallback_compiler_options do
      if Code.ensure_loaded?(EXLA), do: [compiler: EXLA, client: :host], else: []
    end
  end
end

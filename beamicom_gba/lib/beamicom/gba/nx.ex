if Code.ensure_loaded?(Nx.Defn) do
  defmodule Beamicom.GBA.Nx do
    @moduledoc "Compile-time Nx renderer support for the GBA core."

    @ppu_renderer Application.compile_env(:beamicom_gba, :ppu_renderer, :scalar)

    @doc "Returns the renderer selected when the core was compiled."
    def backends, do: %{ppu: @ppu_renderer}

    @doc false
    def compile(function, args) do
      Nx.Defn.compile(function, Enum.map(args, &Nx.to_template/1), compiler_options())
    end

    @doc false
    def backend, do: Nx.Defn.to_backend(compiler_options())

    @doc false
    def compiler_options do
      case Nx.Defn.default_options() do
        [] -> fallback_compiler_options()
        options -> options
      end
    end

    defp fallback_compiler_options do
      if Code.ensure_loaded?(EXLA), do: [compiler: EXLA, client: :host], else: []
    end
  end
end

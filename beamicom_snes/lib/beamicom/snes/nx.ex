if Code.ensure_loaded?(Nx.Defn) do
  defmodule Beamicom.SNES.Nx do
    @moduledoc false

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

    defp fallback_compiler_options do
      if Code.ensure_loaded?(EXLA), do: [compiler: EXLA, client: :host], else: []
    end
  end
end

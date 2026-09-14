if Code.ensure_loaded?(Nx.Defn) do
  defmodule Beamicom.GB.Nx do
    @moduledoc """
    Compile-time Nx renderer selection for the Game Boy core.

    A consuming application configures `:beamicom_gbc` while its dependency is
    compiled. Renderer selection is fixed for the build and is never read from
    the application environment while an emulator is running.
    """

    @ppu_renderer Application.compile_env(:beamicom_gbc, :ppu_renderer, :native)
    @apu_renderer Application.compile_env(:beamicom_gbc, :apu_renderer, :native)

    @doc "Returns the renderer modules selected when the Game Boy core was compiled."
    def backends, do: %{ppu: @ppu_renderer, apu: @apu_renderer}

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

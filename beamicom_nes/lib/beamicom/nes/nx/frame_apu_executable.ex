if Code.ensure_loaded?(Nx.Defn) do
  defmodule Beamicom.NES.Nx.FrameAPUExecutable do
    @moduledoc """
    Platform-specific EXLA disk image for the 48 kHz frame APU graph.

    As with the frame-video cache, Nx 1.0's public compile API is given an EXLA
    disk-cache path. Installed EXLA 1.0 routes that through
    `EXLA.Executable.dump/1` and `EXLA.Executable.load/2`.
    """

    use GenServer

    import Nx.Defn
    require Logger

    alias Beamicom.NES.APU, as: NativeAPU
    alias Beamicom.NES.Nx.{APU, BlockAPU, FrameAudioMath}

    @event_capacity 128
    @sample_capacity 4096
    @default_name __MODULE__

    defn run({apu, kernel}, events, event_count, cycles, dmc, expansion) do
      {apu, pcm, count, left, consumed, input_count} =
        BlockAPU.run_frame_48(apu, events, event_count, cycles, dmc, expansion, kernel)

      {{apu, kernel}, pcm, count, left, consumed, input_count}
    end

    def start_link(options) do
      path = Keyword.fetch!(options, :path)
      name = Keyword.get(options, :name, @default_name)
      GenServer.start_link(__MODULE__, {path, name}, name: name)
    end

    @doc "Compile templates and atomically replace a platform-specific cache file."
    def dump(path) when is_binary(path) do
      temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

      try do
        _compiled = compile(temporary)
        File.mkdir_p!(Path.dirname(path))
        File.rename!(temporary, path)
        :ok
      after
        File.rm(temporary)
      end
    end

    @doc "Load the cache, compiling in memory if an existing dump is incompatible."
    def load(path) when is_binary(path) do
      source = if File.regular?(path), do: :disk, else: :compiled

      try do
        {:ok, compile(path), source}
      rescue
        exception ->
          Logger.warning(
            "NES frame-APU EXLA cache failed at #{inspect(path)}; compiling in memory: " <>
              Exception.message(exception)
          )

          {:ok, compile(false), :fallback_compiled}
      end
    end

    @doc "Return the boot-loaded function, or nil when no cache loader was configured."
    def loaded(server \\ @default_name), do: :persistent_term.get(server, nil)

    @doc "Invoke the boot-loaded executable without a GenServer call."
    def render(arguments, server \\ @default_name) when is_list(arguments) do
      server
      |> :persistent_term.get()
      |> apply(arguments)
    end

    @doc "Fixed donated templates used for dumping and boot loading."
    def templates do
      state =
        {APU.pack(NativeAPU.new()), FrameAudioMath.sinc_kernel()}
        |> Nx.donatable()
        |> Nx.to_template()

      [
        state,
        Nx.template({@event_capacity, 3}, :s32),
        Nx.template({}, :s32),
        Nx.template({}, :s32),
        Nx.template({@sample_capacity}, :s32),
        Nx.template({@sample_capacity}, :f64)
      ]
    end

    @impl true
    def init({path, name}) do
      {:ok, compiled, source} = load(path)
      :persistent_term.put(name, compiled)
      {:ok, %{path: path, source: source}}
    end

    defp compile(cache) do
      Nx.Defn.compile(&__MODULE__.run/6, templates(), compiler: EXLA, client: :host, cache: cache)
    end
  end
end

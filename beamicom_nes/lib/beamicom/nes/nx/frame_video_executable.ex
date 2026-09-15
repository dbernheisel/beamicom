if Code.ensure_loaded?(Nx.Defn) do
  defmodule Beamicom.NES.Nx.FrameVideoExecutable do
    @moduledoc """
    Platform-specific EXLA disk image for the mapper-0 raw-state video defn.

    Nx 1.0's public Nx.Defn.compile/3 returns only a wrapped function, not its
    EXLA executable struct. EXLA 1.0 exposes executable serialization through
    the compiler's cache-path option: its EXLA.Defn.Disk implementation calls
    EXLA.Executable.dump/1 when creating the file and
    EXLA.Executable.load(client, dump) when reopening it.
    """

    use GenServer

    require Logger

    alias Beamicom.NES.Nx.FrameVideo

    @write_capacity 256
    @default_name __MODULE__

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

    @doc "Load the cached executable, compiling without disk cache on any load failure."
    def load(path) when is_binary(path) do
      source = if File.regular?(path), do: :disk, else: :compiled

      try do
        {:ok, compile(path), source}
      rescue
        exception ->
          Logger.warning(
            "NES frame-video EXLA cache failed at #{inspect(path)}; compiling in memory: " <>
              Exception.message(exception)
          )

          {:ok, compile(false), :fallback_compiled}
      end
    end

    @doc "Invoke the boot-loaded executable without a GenServer call."
    def render(arguments, server \\ @default_name) when is_list(arguments) do
      server
      |> :persistent_term.get()
      |> apply(arguments)
    end

    @doc "Fixed templates used by both release dumping and boot loading."
    def templates do
      [
        Nx.template({2048}, :u8),
        Nx.template({256}, :u8),
        Nx.template({512, 8, 8}, :u8),
        Nx.template({@write_capacity, 3}, :s32),
        Nx.template({}, :s32),
        Nx.template({7}, :s32)
      ]
    end

    @impl true
    def init({path, name}) do
      {:ok, compiled, source} = load(path)
      :persistent_term.put(name, compiled)
      {:ok, %{path: path, source: source}}
    end

    defp compile(cache) do
      Nx.Defn.compile(&FrameVideo.render/6, templates(),
        compiler: EXLA,
        client: :host,
        cache: cache
      )
    end
  end
end

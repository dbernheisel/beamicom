defmodule Mix.Tasks.Gb.Bench do
  @shortdoc "Measure deterministic uncapped Game Boy audio/video emulation"
  @moduledoc """
  mix gb.bench ROM [--state SAVE.png] [--frames 120] [--repeats 3] [--renderer native|nx] [--audio-renderer native|elixir_block|nx]

  Runs from either the dependency-free core or an optional renderer project.
  One complete untimed run warms loaded code and compiled renderer programs.
  A share-image state can be supplied to replay gameplay instead of the boot
  sequence; its cartridge identity must match ROM.
  """

  use Mix.Task

  @compile {:no_warn_undefined, Beamicom.GB.Nx.PPURenderer}
  @compile {:no_warn_undefined, Beamicom.GB.Nx.APUSynthRenderer}

  @impl true
  def run(args) do
    {opts, [path], []} =
      OptionParser.parse(args,
        strict: [
          state: :string,
          frames: :integer,
          repeats: :integer,
          renderer: :string,
          audio_renderer: :string
        ]
      )

    Mix.Task.run("app.start")
    frames = Keyword.get(opts, :frames, 120)
    repeats = Keyword.get(opts, :repeats, 3)
    configured_ppu = Beamicom.GB.PPU.configured_renderer()
    configured_apu = Beamicom.GB.APU.configured_renderer()

    renderer =
      renderer(Keyword.get(opts, :renderer, renderer_name(configured_ppu) |> to_string()))

    audio_renderer =
      audio_renderer(
        Keyword.get(opts, :audio_renderer, renderer_name(configured_apu) |> to_string())
      )

    if frames < 1 or repeats < 1, do: Mix.raise("frames and repeats must be positive")

    ensure_compiled!(:ppu, renderer, configured_ppu)
    ensure_compiled!(:apu, audio_renderer, configured_apu)
    media = File.read!(path)
    {machine, state_sha256} = load_machine!(media, path, Keyword.get(opts, :state))
    execute(machine, frames)
    runs = for _ <- 1..repeats, do: execute(machine, frames)

    hashes = Enum.map(runs, &{&1.video_sha256, &1.audio_sha256})
    if length(Enum.uniq(hashes)) != 1, do: Mix.raise("non-deterministic output")
    median_fps = runs |> Enum.map(& &1.fps) |> Enum.sort() |> median()

    IO.inspect(%{
      rom_sha256: hash(media),
      state_sha256: state_sha256,
      start_frame: machine.bus.ppu.frame_number,
      frames: frames,
      renderer: renderer_name(renderer),
      audio_renderer: renderer_name(audio_renderer),
      median_fps: median_fps,
      runs: runs
    })
  end

  defp execute(machine, frames) do
    :erlang.garbage_collect()

    {microseconds, {_machine, video, audio}} =
      :timer.tc(fn ->
        Enum.reduce(1..frames, {machine, [], []}, fn _, {machine, video, audio} ->
          {machine, [video_frame, audio_chunk]} = Beamicom.GB.System.run_slice(machine)
          {machine, [video_frame.data | video], [audio_chunk.data | audio]}
        end)
      end)

    %{
      fps: frames * 1_000_000 / microseconds,
      wall_ms: microseconds / 1_000,
      video_sha256: video |> :lists.reverse() |> IO.iodata_to_binary() |> hash(),
      audio_sha256: audio |> :lists.reverse() |> IO.iodata_to_binary() |> hash()
    }
  end

  defp load_machine!(media, _rom_path, nil) do
    case Beamicom.GB.System.load(media, []) do
      {:ok, machine} -> {machine, nil}
      {:error, reason} -> Mix.raise("could not load ROM: #{inspect(reason)}")
    end
  end

  defp load_machine!(media, rom_path, state_path) do
    state = File.read!(state_path)

    case Beamicom.GB.ShareImage.load_image(state, [Path.dirname(rom_path)]) do
      {:ok, machine} ->
        if hash(machine.bus.cartridge.rom) == hash(media) do
          {machine, hash(state)}
        else
          Mix.raise("save-state cartridge does not match ROM")
        end

      {:error, reason} ->
        Mix.raise("could not load save state: #{inspect(reason)}")
    end
  end

  defp renderer("native"), do: :native

  defp renderer("nx") do
    ensure_renderer!(Beamicom.GB.Nx.PPURenderer)
  end

  defp renderer(_), do: Mix.raise("renderer must be native or nx")

  defp audio_renderer("native"), do: :native
  defp audio_renderer("elixir_block"), do: Beamicom.GB.APUBlockRenderer

  defp audio_renderer("nx") do
    ensure_renderer!(Beamicom.GB.Nx.APUSynthRenderer)
  end

  defp audio_renderer(_),
    do: Mix.raise("audio-renderer must be native, elixir_block, or nx")

  defp ensure_renderer!(module) do
    if Code.ensure_loaded?(module),
      do: module,
      else: Mix.raise("Nx renderers require Nx/EXLA and BEAMICOM_NX=1 at compile time")
  end

  defp ensure_compiled!(_device, renderer, renderer), do: :ok

  defp ensure_compiled!(device, requested, configured) do
    Mix.raise(
      "#{device} renderer is compile-time: requested #{renderer_name(requested)}, " <>
        "but this build contains #{renderer_name(configured)}"
    )
  end

  defp renderer_name(:native), do: :native
  defp renderer_name(Beamicom.GB.APUBlockRenderer), do: :elixir_block
  defp renderer_name(Beamicom.GB.Nx.PPURenderer), do: :nx
  defp renderer_name(Beamicom.GB.Nx.APUSynthRenderer), do: :nx

  defp median(values) do
    midpoint = div(length(values), 2)

    if rem(length(values), 2) == 1,
      do: Enum.at(values, midpoint),
      else: (Enum.at(values, midpoint - 1) + Enum.at(values, midpoint)) / 2
  end

  defp hash(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end

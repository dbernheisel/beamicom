defmodule Mix.Tasks.Gb.Bench do
  @shortdoc "Measure deterministic uncapped Game Boy audio/video emulation"
  @moduledoc """
  mix gb.bench ROM [--frames 120] [--repeats 3] [--renderer native|nx] [--audio-renderer native|elixir_block|nx_block|nx_synth]

  Runs from either the dependency-free core or an optional renderer project.
  One complete untimed run warms loaded code and compiled renderer programs.
  """

  use Mix.Task

  @compile {:no_warn_undefined, Beamicom.GB.Nx.PPURenderer}
  @compile {:no_warn_undefined, Beamicom.GB.Nx.APUBlockRenderer}
  @compile {:no_warn_undefined, Beamicom.GB.Nx.APUSynthRenderer}

  @impl true
  def run(args) do
    {opts, [path], []} =
      OptionParser.parse(args,
        strict: [frames: :integer, repeats: :integer, renderer: :string, audio_renderer: :string]
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
    execute(media, frames)
    runs = for _ <- 1..repeats, do: execute(media, frames)

    hashes = Enum.map(runs, &{&1.video_sha256, &1.audio_sha256})
    if length(Enum.uniq(hashes)) != 1, do: Mix.raise("non-deterministic output")

    IO.inspect(%{
      rom_sha256: hash(media),
      frames: frames,
      renderer: renderer_name(renderer),
      audio_renderer: renderer_name(audio_renderer),
      runs: runs
    })
  end

  defp execute(media, frames) do
    {:ok, machine} = Beamicom.GB.System.load(media, [])
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

  defp renderer("native"), do: :native

  defp renderer("nx") do
    ensure_renderer!(Beamicom.GB.Nx.PPURenderer)
  end

  defp renderer(_), do: Mix.raise("renderer must be native or nx")

  defp audio_renderer("native"), do: :native
  defp audio_renderer("elixir_block"), do: Beamicom.GB.APUBlockRenderer

  defp audio_renderer("nx_block") do
    ensure_renderer!(Beamicom.GB.Nx.APUBlockRenderer)
  end

  defp audio_renderer("nx_synth") do
    ensure_renderer!(Beamicom.GB.Nx.APUSynthRenderer)
  end

  defp audio_renderer(_),
    do: Mix.raise("audio-renderer must be native, elixir_block, nx_block, or nx_synth")

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
  defp renderer_name(Beamicom.GB.Nx.APUBlockRenderer), do: :nx_block
  defp renderer_name(Beamicom.GB.Nx.APUSynthRenderer), do: :nx_synth

  defp hash(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end

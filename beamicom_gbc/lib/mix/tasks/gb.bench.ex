defmodule Mix.Tasks.Gb.Bench do
  @shortdoc "Measure deterministic uncapped Game Boy audio/video emulation"
  @moduledoc """
  mix gb.bench ROM [--frames 120] [--repeats 3] [--renderer native|nx] [--audio-renderer native|nx_block|nx_synth]

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
    renderer = renderer(Keyword.get(opts, :renderer, "native"))
    audio_renderer = audio_renderer(Keyword.get(opts, :audio_renderer, "native"))

    if frames < 1 or repeats < 1, do: Mix.raise("frames and repeats must be positive")

    Application.put_env(:beamicom_gbc, :ppu_renderer, renderer)
    Application.put_env(:beamicom_gbc, :apu_renderer, audio_renderer)
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

  defp audio_renderer("nx_block") do
    ensure_renderer!(Beamicom.GB.Nx.APUBlockRenderer)
  end

  defp audio_renderer("nx_synth") do
    ensure_renderer!(Beamicom.GB.Nx.APUSynthRenderer)
  end

  defp audio_renderer(_), do: Mix.raise("audio-renderer must be native, nx_block, or nx_synth")

  defp ensure_renderer!(module) do
    if Code.ensure_loaded?(module),
      do: module,
      else: Mix.raise("Nx renderers require running this task from beamicom_gbc_nx")
  end

  defp renderer_name(:native), do: :native
  defp renderer_name(Beamicom.GB.Nx.PPURenderer), do: :nx
  defp renderer_name(Beamicom.GB.Nx.APUBlockRenderer), do: :nx_block
  defp renderer_name(Beamicom.GB.Nx.APUSynthRenderer), do: :nx_synth

  defp hash(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end

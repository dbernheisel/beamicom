alias NxNes.Machine
alias NxNes.Machine.Reference

{opts, _, _} =
  OptionParser.parse(System.argv(),
    strict: [frames: :integer, output: :string, entry: :integer, start_frame: :integer]
  )

frames = Keyword.get(opts, :frames, 902)
output = Keyword.get(opts, :output, "results/machine_bench.json")
media = File.read!("../../beamicom/roms/castlevania3.nes")
{:ok, initial} = Machine.load(media)
IO.puts("Compiling resident MMC5 frame runner")

{compile_us, fun} =
  :timer.tc(fn -> Machine.compile(initial, media, entry: Keyword.get(opts, :entry, 0xE047)) end)

IO.puts("Compiled in #{compile_us / 1_000_000} s")
File.mkdir_p!("tmp/machine")
start_frame = Keyword.get(opts, :start_frame)
# A warmup is not included in timings, and state is reset for the measured boot.
{warm, _} = fun.(initial, Nx.tensor(0, type: :s32), Nx.tensor(0, type: :s32))
Nx.to_number(warm.cycles)

init = %{
  s: initial,
  native: Beamicom.NES.Console.load_binary(media),
  times: [],
  native_times: [],
  audio: [],
  fast: 0,
  instructions: 0,
  video_hash: :crypto.hash_init(:sha256),
  audio_hash: :crypto.hash_init(:sha256)
}

result =
  Enum.reduce(1..frames, init, fn frame, acc ->
    pad = if start_frame && frame in start_frame..(start_frame + 2), do: 8, else: 0

    {us, {s, instructions}} =
      :timer.tc(fn ->
        {s, n} = fun.(acc.s, Nx.tensor(pad, type: :s32), Nx.tensor(0, type: :s32))
        Nx.to_number(s.cycles)
        {s, Nx.to_number(n)}
      end)

    {native_us, {native, _count, pcm}} = :timer.tc(fn -> Reference.frame(acc.native, pad, 0) end)

    try do
      Reference.compare!(s, native, pcm)
    rescue
      e ->
        File.write!(
          "tmp/machine/failure.etf",
          :erlang.term_to_binary({Nx.backend_copy(s, Nx.BinaryBackend), native}, [:compressed])
        )

        reraise e, __STACKTRACE__
    end

    fast = Nx.to_number(s.fast_instructions)

    if frame <= 3 or rem(frame, 10) == 0 or frame == frames do
      IO.puts(
        "frame #{frame}/#{frames}: #{Float.round(us / 1000, 2)} ms; #{fast}/#{instructions} instructions fused; CPU/memory/video/PCM exact"
      )

      File.write!(
        "tmp/machine/progress.json",
        IO.iodata_to_binary(
          :json.encode(%{
            frame: frame,
            frames: frames,
            core_ms: Enum.sum(acc.times) / 1000 + us / 1000,
            last_frame_ms: us / 1000
          })
        )
      )
    end

    if rem(frame, 60) == 0 or frame == frames do
      f = Machine.output(s)
      rgb = Beamicom.NES.Palette.to_rgb(f.framebuffer)
      File.write!("tmp/machine/frame_#{frame}.png", Beamicom.NES.PNG.encode(256, 240, rgb))

      File.write!(
        "tmp/machine/checkpoint.etf",
        :erlang.term_to_binary({Nx.backend_copy(s, Nx.BinaryBackend), native}, [:compressed])
      )
    end

    %{
      acc
      | s: s,
        native: native,
        times: [us | acc.times],
        native_times: [native_us | acc.native_times],
        audio: [pcm | acc.audio],
        fast: acc.fast + fast,
        instructions: acc.instructions + instructions,
        video_hash:
          :crypto.hash_update(
            acc.video_hash,
            Nx.to_binary(s.ppu.framebuffer) <> Nx.to_binary(s.ppu.output_palette)
          ),
        audio_hash: :crypto.hash_update(acc.audio_hash, pcm)
    }
  end)

ms = Enum.sum(result.times) / 1000
pcm = result.audio |> Enum.reverse() |> IO.iodata_to_binary()

File.write!(
  "tmp/machine/audio.wav",
  Beamicom.NES.WAV.encode(for <<v::signed-little-16 <- pcm>>, do: v)
)

report = %{
  scope:
    "Full resident MMC5 Castlevania III; one compiled call per frame; native differential checks outside timing",
  frames: frames,
  input:
    if(start_frame,
      do: "Start pressed at frame #{start_frame} for three frames",
      else: "cold boot; no input"
    ),
  sequential_diagnostic: System.get_env("NX_APU_FORCE_SEQUENTIAL") != nil,
  compile_ms: compile_us / 1000,
  core_ms: ms,
  fps: frames * 1000 / ms,
  native_core_ms: Enum.sum(result.native_times) / 1000,
  frame_times_us: Enum.reverse(result.times),
  native_frame_times_us: Enum.reverse(result.native_times),
  instructions: result.instructions,
  fused_instructions: result.fast,
  cpu_cycles: Nx.to_number(result.s.cycles),
  audio_samples: div(byte_size(pcm), 2),
  video_sha256: Base.encode16(:crypto.hash_final(result.video_hash), case: :lower),
  audio_sha256: Base.encode16(:crypto.hash_final(result.audio_hash), case: :lower),
  rom_sha256: Base.encode16(:crypto.hash(:sha256, media), case: :lower),
  validation:
    "Every frame: CPU/NMI/IRQ, RAM/WRAM, mapper registers/banks, PPU control/VRAM/OAM/ExRAM, pixels/palette, PCM exact; APU floats within 1e-9"
}

File.write!(output, IO.iodata_to_binary(:json.encode(report)) <> "\n")
IO.inspect(Map.drop(report, [:frame_times_us, :native_frame_times_us]))

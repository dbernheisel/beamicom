defmodule ApuEventsCapture do
  def tick(n), do: Process.put(:apu_time, Process.get(:apu_time, 0) + n)

  def event(addr, val),
    do:
      Process.put(:apu_events, [
        {Process.get(:apu_time, 0), addr, val} | Process.get(:apu_events, [])
      ])

  def run(path) do
    Code.compiler_options(ignore_module_conflict: true)
    source = File.read!("../../beamicom/lib/nes/apu.ex")

    source =
      source
      |> String.replace("def tick(", "def original_tick(")
      |> String.replace(
        "  @flush_threshold 100",
        "  @flush_threshold 100\n  def tick(s, n) do\n ApuEventsCapture.tick(n)\n original_tick(s, n)\n end"
      )
      |> String.replace(
        "def write(apu, addr, val), do: write_reg(flush(apu), addr, val)",
        "def write(apu, addr, val) do\n ApuEventsCapture.event(addr, val)\n write_reg(flush(apu), addr, val)\n end"
      )
      |> String.replace(
        "def mmc5_write(apu, addr, val) do",
        "def mmc5_write(apu, addr, val) do\n ApuEventsCapture.event(addr, val)"
      )
      |> String.replace(
        "def read_status(apu) do",
        "def read_status(apu) do\n ApuEventsCapture.event(0x4015, -1)"
      )

    Code.compile_string(source, "apu_event_capture.ex")
    media = File.read!(path)
    {:ok, c} = Beamicom.NES.System.load(media)
    initial = c.bus.apu

    {c, chunks} =
      Enum.reduce(1..902, {c, []}, fn _, {c, chunks} ->
        {c, [_, audio]} = Beamicom.NES.System.run_slice(c)
        {c, [audio.data | chunks]}
      end)

    data = %{
      initial: initial,
      final: c.bus.apu,
      cycles: Process.get(:apu_time),
      events: Enum.reverse(Process.get(:apu_events, [])),
      pcm: IO.iodata_to_binary(Enum.reverse(chunks)),
      rom_sha256: Base.encode16(:crypto.hash(:sha256, media), case: :lower)
    }

    File.write!("tmp/apu_events.etf", :erlang.term_to_binary(data, [:compressed]))

    IO.inspect(%{
      cycles: data.cycles,
      events: length(data.events),
      registers: Enum.frequencies_by(data.events, &elem(&1, 1)),
      samples: div(byte_size(data.pcm), 2)
    })
  end
end

ApuEventsCapture.run(hd(System.argv()))

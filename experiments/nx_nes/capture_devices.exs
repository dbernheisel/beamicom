defmodule DeviceCapture do
  @frames [0, 60, 180, 300, 420, 540, 660, 780, 900]
  def ppu(s) do
    Process.put(:capture_frame, s.frame)

    if s.frame in @frames do
      sample = Map.drop(Map.from_struct(s), [:chr, :fb, :frame_ready])
      Process.put(:ppu_samples, [sample | Process.get(:ppu_samples, [])])
    end
  end

  def apu(s, dc) do
    if Process.get(:capture_frame) in @frames do
      Process.put(:apu_samples, [{%{s | samples: []}, dc} | Process.get(:apu_samples, [])])
    end
  end

  def run(path) do
    Code.compiler_options(ignore_module_conflict: true)

    for {file, from, to} <- [
          {"ppu", "defp render_scanline(ppu) do",
           "defp render_scanline(ppu) do\n DeviceCapture.ppu(ppu)"},
          {"apu", "defp advance(apu, dc) do",
           "defp advance(apu, dc) do\n DeviceCapture.apu(apu, dc)"}
        ] do
      File.read!("../../beamicom/lib/nes/#{file}.ex")
      |> String.replace(from, to)
      |> Code.compile_string("capture_#{file}.ex")
    end

    media = File.read!(path)
    {:ok, c} = Beamicom.NES.System.load(media)
    Enum.reduce(1..902, c, fn _, c -> elem(Beamicom.NES.System.run_slice(c), 0) end)

    data = %{
      rom_sha256: Base.encode16(:crypto.hash(:sha256, media), case: :lower),
      chr: c.bus.ppu.chr,
      ppu: Enum.reverse(Process.get(:ppu_samples)),
      apu: Enum.reverse(Process.get(:apu_samples))
    }

    File.mkdir_p!("tmp")
    File.write!("tmp/devices.etf", :erlang.term_to_binary(data, [:compressed]))

    IO.inspect(%{
      ppu_lines: length(data.ppu),
      apu_segments: length(data.apu),
      ppu_modes: Enum.frequencies_by(data.ppu, &{&1.exram_mode, &1.split_en}),
      dmc_segments: Enum.count(data.apu, fn {a, _} -> a.dmc != nil end),
      mmc5_segments: Enum.count(data.apu, fn {a, _} -> a.m5_active end)
    })
  end
end

DeviceCapture.run(hd(System.argv()))

defmodule NxNes.Machine.Reference do
  @moduledoc "Native differential oracle used only by tests and benchmarks, outside compiled execution."
  alias Beamicom.NES.{Console, Bus}

  def frame(c, pad1 \\ 0, pad2 \\ 0) do
    bus = c.bus |> Bus.set_buttons(1, pad1) |> Bus.set_buttons(2, pad2)
    c = %{c | bus: bus}
    target = if c.bus.ppu.frame_ready, do: c.bus.ppu.frame_ready.number + 1, else: 0
    c = until_frame(c, target)
    {count, pcm, bus} = Bus.take_audio_pcm(c.bus)
    {%{c | bus: bus}, count, pcm}
  end

  defp until_frame(c, target) do
    c = Console.step(c)

    if c.bus.ppu.frame_ready && c.bus.ppu.frame_ready.number == target,
      do: c,
      else: until_frame(c, target)
  end

  def compare!(s, c, pcm) do
    equal!(
      NxNes.Core.cpu(s),
      Map.take(Map.from_struct(c.cpu), [:a, :x, :y, :sp, :p, :pc, :cycles]),
      :cpu
    )

    equal!(Nx.to_number(s.reason), 0, :reason)
    equal!(Nx.to_binary(s.ram), c.bus.ram, :ram)

    wram =
      for i <- 0..(Nx.axis_size(s.wram, 0) - 1),
          into: <<>>,
          do: <<Map.get(c.bus.wram, 0x6000 + i, 0)>>

    equal!(Nx.to_binary(s.wram), wram, :wram)
    equal!(Nx.to_flat_list(s.prg_banks), Tuple.to_list(c.bus.prg_banks), :prg_banks)

    for k <- [:nmi_prev, :nmi_edge, :nmi_pending],
        do: equal!(Nx.to_number(s[k]), int(Map.fetch!(c.cpu, k)), k)

    for k <- [:irq_pending, :irq_enabled],
        do: equal!(Nx.to_number(s[k]), int(Map.fetch!(c.bus, k)), k)

    for {k, t} <- s.mapper do
      v = Map.fetch!(c.bus.mapper_state, k)

      if is_tuple(v),
        do: equal!(Nx.to_flat_list(t), Tuple.to_list(v), k),
        else: equal!(Nx.to_number(t), v, k)
    end

    for k <- [
          :v,
          :t,
          :x,
          :w,
          :ctrl,
          :mask,
          :status,
          :dot,
          :scanline,
          :frame,
          :oam_addr,
          :buffer,
          :exram_mode,
          :fill_tile,
          :fill_attr,
          :ext_chr_hi,
          :split_en,
          :split_side,
          :split_tile,
          :split_scroll,
          :split_chr
        ] do
      equal!(Nx.to_number(s.ppu[k]), int(Map.fetch!(c.bus.ppu, k)), {:ppu, k})
    end

    equal!(Nx.to_binary(s.ppu.vram), c.bus.ppu.vram, :vram)
    equal!(Nx.to_binary(s.ppu.oam), c.bus.ppu.oam, :oam)

    equal!(
      Nx.to_flat_list(s.ppu.exram),
      for(i <- 0..1023, do: Map.get(c.bus.ppu.exram, i, 0)),
      :exram
    )

    for k <- [:chr_banks, :bg_chr_banks],
        do: equal!(Nx.to_flat_list(s.ppu[k]), Tuple.to_list(Map.fetch!(c.bus.ppu, k)), k)

    equal!(Nx.to_binary(s.ppu.framebuffer), c.bus.ppu.frame_ready.pixels, :pixels)
    equal!(Nx.to_binary(s.ppu.output_palette), c.bus.ppu.frame_ready.palette, :palette)
    equal!(Nx.to_number(s.ppu.ready), c.bus.ppu.frame_ready.number, :frame_number)
    equal!(Nx.to_number(s.audio_count) * 2, byte_size(pcm), :audio_count)
    equal!(binary_part(Nx.to_binary(s.audio), 0, byte_size(pcm)), pcm, :pcm)
    compare_audio!(s.apu, NxNes.APU.pack(c.bus.apu), [])
    :ok
  end

  defp compare_audio!(a, b, path) do
    for {k, v} <- a do
      if is_struct(v, Nx.Tensor) do
        actual = Nx.to_number(v)
        expected = Nx.to_number(b[k])

        if is_float(expected) do
          if abs(actual - expected) > 1.0e-9,
            do:
              raise(
                "APU differs at #{inspect(Enum.reverse([k | path]))}: #{actual} != #{expected}"
              )
        else
          equal!(actual, expected, {:apu, Enum.reverse([k | path])})
        end
      else
        compare_audio!(v, b[k], [k | path])
      end
    end
  end

  defp equal!(a, b, _label) when a == b, do: :ok

  defp equal!(a, b, label),
    do: raise("#{inspect(label)} mismatch: #{inspect(a, limit: 10)} != #{inspect(b, limit: 10)}")

  defp int(true), do: 1
  defp int(false), do: 0
  defp int(x), do: x
end

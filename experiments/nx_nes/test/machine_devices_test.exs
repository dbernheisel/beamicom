defmodule NxNes.MachineDevicesTest do
  use ExUnit.Case, async: false
  alias NxNes.Machine
  alias NxNes.Machine.{Mapper, PPU, Bus}

  defp fixture do
    prg = for i <- 0..32767, into: <<>>, do: <<rem(div(i, 8192) * 31 + i, 256)>>
    chr = for i <- 0..8191, into: <<>>, do: <<rem(i * 17 + div(i, 1024), 256)>>
    media = <<"NES", 26, 2, 1, 0x50, 0, 0::64>> <> prg <> chr
    {:ok, s} = Machine.load(media)
    {s, Beamicom.NES.Console.load_binary(media).bus}
  end

  defp scalar(v), do: Nx.tensor(v, type: :s32)

  defp same_mapper(s, b) do
    assert Nx.to_flat_list(s.prg_banks) == Tuple.to_list(b.prg_banks)
    assert Nx.to_flat_list(s.ppu.chr_banks) == Tuple.to_list(b.ppu.chr_banks)
    assert Nx.to_flat_list(s.ppu.bg_chr_banks) == Tuple.to_list(b.ppu.bg_chr_banks)

    for k <- [:wram_bank, :prg_ram_windows, :prg_mode, :chr_mode, :irq_latch, :mul_a, :mul_b],
        do: assert(Nx.to_number(s.mapper[k]) == b.mapper_state[k], "#{k}")
  end

  test "MMC5 banking and multiplier agree across all PRG and CHR modes" do
    {s, bus} = fixture()
    write = EXLA.jit(&Mapper.write/3, client: :host)
    read = EXLA.jit(&Mapper.read/2, client: :host)

    events =
      for mode <- 0..3,
          {a, v} <- [
            {0x5100, mode},
            {0x5113, 7},
            {0x5114, 1},
            {0x5115, 0x83},
            {0x5116, 2},
            {0x5117, 0xFF},
            {0x5101, mode},
            {0x5120, 7},
            {0x5123, 2},
            {0x5127, 3},
            {0x512B, 5},
            {0x5130, 3},
            {0x5205, 255},
            {0x5206, 127}
          ],
          do: {a, v}

    {s, bus} =
      Enum.reduce(events, {s, bus}, fn {a, v}, {s, b} ->
        s = write.(s, scalar(a), scalar(v))
        b = Beamicom.NES.Mapper.write(b, a, v)
        same_mapper(s, b)
        {s, b}
      end)

    for a <- [0x5204, 0x5205, 0x5206] do
      {v, _} = read.(s, scalar(a))
      {expected, _} = Beamicom.NES.Mapper.read(bus, a)
      assert Nx.to_number(v) == expected
    end
  end

  test "PPU register buffering, palette mirrors, OAM and frame timing match native" do
    {s, bus} = fixture()
    write = EXLA.jit(&PPU.write_register/3, client: :host)
    read = EXLA.jit(&PPU.read_register/3, client: :host)
    run = EXLA.jit(&PPU.run/3, client: :host)

    events = [
      {0x2000, 0xA0},
      {0x2005, 7},
      {0x2005, 23},
      {0x2006, 0x3F},
      {0x2006, 0x10},
      {0x2007, 42},
      {0x2003, 254},
      {0x2004, 255},
      {0x2004, 1},
      {0x2004, 2},
      {0x2006, 0x20},
      {0x2006, 0},
      {0x2007, 19},
      {0x2006, 0x20},
      {0x2006, 0}
    ]

    {p, native} =
      Enum.reduce(events, {s.ppu, bus.ppu}, fn {a, v}, {p, n} ->
        {write.(p, scalar(a), scalar(v)), Beamicom.NES.PPU.write_register(n, a, v)}
      end)

    {p, native} =
      Enum.reduce([0x2007, 0x2007, 0x2002, 0x2004], {p, native}, fn a, {p, n} ->
        {v, p} = read.(p, s.chr, scalar(a))
        {expected, n} = Beamicom.NES.PPU.read_register(n, a)
        assert Nx.to_number(v) == expected
        {p, n}
      end)

    p = write.(p, scalar(0x2001), scalar(0x1E))
    native = Beamicom.NES.PPU.write_register(native, 0x2001, 0x1E)

    Enum.reduce([1, 256, 3, 20, 61, 81_500, 500, 7000, 90_000], {p, native}, fn dots, {p, n} ->
      p = run.(p, s.chr, scalar(dots))
      n = Beamicom.NES.PPU.run(n, dots)

      for k <- [:dot, :scanline, :frame, :v, :t, :status, :irq_ticks, :irq_scanline],
          do: assert(Nx.to_number(p[k]) == Map.fetch!(n, k), "#{k}")

      assert Nx.to_binary(p.oam) == n.oam
      assert Nx.to_binary(p.vram) == n.vram
      {p, n}
    end)
  end

  test "MMC5 RAM windows, protection and mirrored DMA use resident memory" do
    {s, _} = fixture()
    write = EXLA.jit(&Bus.write/3, client: :host)
    peek = EXLA.jit(&Bus.peek/2, client: :host)
    events = [{0x5114, 0}, {0x6000, 99}, {0x8000, 17}, {0x5102, 2}, {0x5103, 1}, {0x8000, 42}]
    s = Enum.reduce(events, s, fn {a, v}, s -> write.(s, scalar(a), scalar(v)) end)
    assert Nx.to_number(peek.(s, scalar(0x6000))) == 42
    assert Nx.to_number(peek.(s, scalar(0x8000))) == 42
    s = write.(s, scalar(0x800), scalar(31))
    s = write.(s, scalar(0x2003), scalar(255))
    s = write.(s, scalar(0x4014), scalar(8))
    assert Nx.to_number(s.dma) == 1
    assert :binary.at(Nx.to_binary(s.ppu.oam), 255) == 31
  end
end

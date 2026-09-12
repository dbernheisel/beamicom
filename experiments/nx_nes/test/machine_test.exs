defmodule NxNes.MachineTest do
  use ExUnit.Case, async: false
  alias NxNes.Machine
  alias NxNes.Machine.Reference

  @tag timeout: 240_000
  test "resident frames match native through DMA, NMI, rendering and guarded CPU batches" do
    prefix = [
      0x78,
      0xA9,
      0x40,
      0x8D,
      0x17,
      0x40,
      0xA9,
      0x18,
      0x8D,
      1,
      0x20,
      0xA9,
      8,
      0x8D,
      0x14,
      0x40,
      0xA9,
      0x80,
      0x8D,
      0,
      0x20
    ]

    entry = 0xE000 + length(prefix)

    loop = [
      0xE6,
      0x10,
      0x18,
      0xA5,
      0x10,
      0x65,
      0x11,
      0x85,
      0x10,
      0x4C,
      Bitwise.band(entry, 255),
      Bitwise.bsr(entry, 8)
    ]

    code = :erlang.list_to_binary(prefix ++ loop)
    prg = :binary.copy(<<0>>, 32768)
    prg = patch(prg, 0x6000, code)
    prg = patch(prg, 0x6100, <<0xE6, 0x12, 0x40>>)
    prg = patch(prg, 0x7FFA, <<0, 0xE1, 0, 0xE0, 0, 0xE1>>)
    chr = for i <- 0..8191, into: <<>>, do: <<rem(i * 17, 256)>>
    media = <<"NES", 26, 2, 1, 0x50, 0, 0::64>> <> prg <> chr
    {:ok, s} = Machine.load(media)
    assert %EXLA.Backend{} = s.prg.data
    fun = Machine.compile(s, media, entry: entry)
    native = Beamicom.NES.Console.load_binary(media)

    {s, _} =
      Enum.reduce(1..3, {s, native}, fn _, {s, native} ->
        {s, _} = fun.(s, Nx.tensor(0, type: :s32), Nx.tensor(0, type: :s32))
        {native, _, pcm} = Reference.frame(native)
        assert :ok == Reference.compare!(s, native, pcm)
        assert Machine.status(s) == :running
        assert %EXLA.Backend{} = s.ram.data
        assert %EXLA.Backend{} = s.ppu.framebuffer.data
        {s, native}
      end)

    assert Nx.to_number(s.fast_instructions) + Nx.to_number(s.batched_instructions) > 0
    output = Machine.output(s)
    assert byte_size(output.framebuffer.pixels) == 256 * 240
    assert byte_size(output.pcm) == output.audio_samples * 2
    assert :binary.at(Nx.to_binary(s.ram), 0x12) > 0
  end

  test "unsupported cartridge formats are explicit" do
    media = <<"NES", 26, 1, 1, 0::80>> <> :binary.copy(<<0>>, 24576)
    assert Machine.load(media) == {:error, :requires_mmc5_chr_rom}
  end

  defp patch(binary, offset, bytes) do
    size = byte_size(bytes)
    <<pre::binary-size(^offset), _::binary-size(^size), post::binary>> = binary
    pre <> bytes <> post
  end
end

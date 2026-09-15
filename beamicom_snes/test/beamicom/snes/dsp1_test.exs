defmodule Beamicom.SNES.DSP1Test do
  use ExUnit.Case, async: true

  import Bitwise

  alias Beamicom.SNES.{Bus, Cartridge, DSP1}
  alias Beamicom.SNESTestROM

  test "detects DSP-1 without claiming DSP-2 or DSP-4 header combinations" do
    {:ok, dsp1} = :lorom |> SNESTestROM.build(cartridge_type: 0x03) |> Cartridge.load()

    {:ok, dsp2} =
      :lorom
      |> SNESTestROM.build(cartridge_type: 0x05, map_mode: 0x20)
      |> Cartridge.load()

    {:ok, dsp4} =
      :lorom
      |> SNESTestROM.build(cartridge_type: 0x03, map_mode: 0x30)
      |> Cartridge.load()

    assert DSP1.cartridge?(dsp1)
    refute DSP1.cartridge?(dsp2)
    refute DSP1.cartridge?(dsp4)
    assert %DSP1{} = Bus.new(dsp1).coprocessor
  end

  test "frames little-endian commands and returns fixed-point multiply output" do
    bus = dsp1_bus(:lorom, cartridge_type: 0x03)

    bus = write_bytes(bus, 0x208000, <<0x00, 0x00, 0x40, 0x00, 0x40>>)
    {low, bus, 8} = Bus.cpu_read(bus, 0x208000)
    {high, bus, 8} = Bus.cpu_read(bus, 0xA08000)
    {idle, _bus, 8} = Bus.cpu_read(bus, 0x208000)

    assert {low, high} == {0x00, 0x20}
    assert idle == 0x80
    assert bus.coprocessor.command_counts == %{0x00 => 1}
  end

  test "maps large LoROM and HiROM windows with their status halves" do
    large = dsp1_bus(:lorom, cartridge_type: 0x03, size: 0x200000)
    hirom = dsp1_bus(:hirom, cartridge_type: 0x05)

    assert DSP1.mapped?(large.coprocessor, 0x600000)
    assert DSP1.mapped?(large.coprocessor, 0xE07FFF)
    refute DSP1.mapped?(large.coprocessor, 0x608000)

    assert DSP1.mapped?(hirom.coprocessor, 0x006000)
    assert DSP1.mapped?(hirom.coprocessor, 0x807FFF)
    refute DSP1.mapped?(hirom.coprocessor, 0x207000)

    assert Bus.peek(large, 0x604000) == 0x80
    assert Bus.peek(hirom, 0x007000) == 0x80
  end

  test "implements radius, range, RAM test, and ROM size scalar commands" do
    bus = dsp1_bus(:lorom, cartridge_type: 0x03)

    bus = write_words(bus, 0x208000, 0x08, [3, 4, 0])
    {radius, bus} = read_bytes(bus, 0x208000, 4)
    assert radius == <<50, 0, 0, 0>>

    bus = write_words(bus, 0x208000, 0x18, [3, 4, 0, 5])
    {range, bus} = read_bytes(bus, 0x208000, 2)
    assert range == <<0, 0>>

    bus = write_words(bus, 0x208000, 0x28, [3, 4, 0])
    {distance, bus} = read_bytes(bus, 0x208000, 2)
    assert distance == <<5, 0>>

    bus = write_words(bus, 0x208000, 0x0F, [0x0100])
    {ram_test, bus} = read_bytes(bus, 0x208000, 2)
    assert ram_test == <<0, 0>>

    bus = write_words(bus, 0x208000, 0x2F, [0])
    {rom_size, _bus} = read_bytes(bus, 0x208000, 2)
    assert rom_size == <<0, 1>>
  end

  test "implements inverse, 3D rotation, and persistent attitude matrices" do
    bus = dsp1_bus(:lorom, cartridge_type: 0x03)

    bus = write_words(bus, 0x208000, 0x10, [0x4000, 0])
    {inverse, bus} = read_words(bus, 0x208000, 2)
    assert inverse == [0x7FFF, 1]

    bus = write_words(bus, 0x208000, 0x01, [0x4000, 0, 0, 0])
    assert Bus.peek(bus, 0x208000) == 0x80

    bus = write_words(bus, 0x208000, 0x0D, [1000, -2000, 3000])
    {objective, bus} = read_signed_words(bus, 0x208000, 3)
    assert objective == [249, -500, 749]

    bus = write_words(bus, 0x208000, 0x03, objective)
    {subjective, bus} = read_signed_words(bus, 0x208000, 3)
    assert subjective == [62, -125, 187]

    bus = write_words(bus, 0x208000, 0x0B, [1000, -2000, 3000])
    {scalar, bus} = read_signed_words(bus, 0x208000, 1)
    assert scalar == [249]

    bus = write_words(bus, 0x208000, 0x1C, [0, 0, 0, 1000, -2000, 3000])
    {rotated, _bus} = read_signed_words(bus, 0x208000, 3)
    assert rotated == [998, -2000, 2998]
  end

  test "retains projection state and streams successive raster matrices" do
    bus = dsp1_bus(:lorom, cartridge_type: 0x03)

    bus = write_words(bus, 0x208000, 0x02, [0, 0, 100, 0, 100, 0, 0])
    {parameters, bus} = read_signed_words(bus, 0x208000, 4)
    assert parameters == [0, -32_767, 0, 0]

    bus = write_words(bus, 0x208000, 0x0A, [0])
    {first_matrix, bus} = read_signed_words(bus, 0x208000, 4)
    {second_matrix, bus} = read_signed_words(bus, 0x208000, 4)
    assert first_matrix == [257, 0, 0, 257]
    assert second_matrix == first_matrix

    # Raster results stream forever. Hardware terminates the stream by
    # discarding one pending result byte per write before accepting a command.
    bus = write_bytes(bus, 0x208000, :binary.copy(<<0>>, 8))

    bus = write_words(bus, 0x208000, 0x06, [10, 0, 0])
    {projected, bus} = read_signed_words(bus, 0x208000, 3)
    assert projected == [9, 0, 253]

    bus = write_words(bus, 0x208000, 0x0E, [0, 0])
    {target, bus} = read_signed_words(bus, 0x208000, 2)
    assert target == [0, 0]
    assert bus.coprocessor.command_counts[0x0A] == 1
    assert bus.coprocessor.unsupported_commands == MapSet.new()
  end

  test "writes consume and terminate a pending Raster result before command framing resumes" do
    bus = dsp1_bus(:lorom, cartridge_type: 0x03)
    bus = write_words(bus, 0x208000, 0x02, [0, 0, 100, 0, 100, 0, 0])
    {_parameters, bus} = read_signed_words(bus, 0x208000, 4)
    bus = write_words(bus, 0x208000, 0x0A, [0])
    bus = write_bytes(bus, 0x208000, :binary.copy(<<0xFF>>, 8))

    bus = write_words(bus, 0x208000, 0x00, [0x4000, 0x4000])
    {product, bus} = read_signed_words(bus, 0x208000, 1)
    assert product == [0x2000]
    assert bus.coprocessor.command_counts == %{0x00 => 1, 0x02 => 1, 0x0A => 1}
    assert bus.coprocessor.unsupported_commands == MapSet.new()
  end

  test "matches DSP-1 fixed-point geometry reference vectors" do
    parameters = [1234, -2345, 8192, 1024, 4096, 7000, 5000]
    bus = dsp1_bus(:lorom, cartridge_type: 0x03)
    bus = write_words(bus, 0x208000, 0x02, parameters)
    {parameter_result, bus} = read_signed_words(bus, 0x208000, 4)
    assert parameter_result == [0, -7879, 3880, -5679]

    bus = write_words(bus, 0x208000, 0x0A, [42])
    {raster, _bus} = read_signed_words(bus, 0x208000, 4)
    assert raster == [498, -447, 396, 562]

    bus = dsp1_bus(:lorom, cartridge_type: 0x03)
    bus = write_words(bus, 0x208000, 0x02, parameters)
    {_parameter_result, bus} = read_signed_words(bus, 0x208000, 4)
    bus = write_words(bus, 0x208000, 0x06, [1500, -1700, 7000])
    {projected, bus} = read_signed_words(bus, 0x208000, 3)
    assert projected == [1297, 1812, 545]

    bus = write_words(bus, 0x208000, 0x0E, [120, -64])
    {target, _bus} = read_signed_words(bus, 0x208000, 2)
    assert target == [4229, -6009]
  end

  defp dsp1_bus(layout, opts) do
    {:ok, cartridge} = layout |> SNESTestROM.build(opts) |> Cartridge.load()
    Bus.new(cartridge)
  end

  defp write_words(bus, address, command, words) do
    parameters = for word <- words, into: <<>>, do: <<word &&& 0xFF, word >>> 8 &&& 0xFF>>
    write_bytes(bus, address, <<command, parameters::binary>>)
  end

  defp write_bytes(bus, address, bytes) do
    Enum.reduce(:binary.bin_to_list(bytes), bus, fn byte, bus ->
      {bus, 8} = Bus.cpu_write(bus, address, byte)
      bus
    end)
  end

  defp read_bytes(bus, address, count) do
    Enum.reduce(1..count, {<<>>, bus}, fn _, {bytes, bus} ->
      {byte, bus, 8} = Bus.cpu_read(bus, address)
      {<<bytes::binary, byte>>, bus}
    end)
  end

  defp read_words(bus, address, count) do
    {bytes, bus} = read_bytes(bus, address, count * 2)
    {for(<<low, high <- bytes>>, do: low ||| high <<< 8), bus}
  end

  defp read_signed_words(bus, address, count) do
    {words, bus} = read_words(bus, address, count)

    words =
      Enum.map(words, fn
        word when word >= 0x8000 -> word - 0x10000
        word -> word
      end)

    {words, bus}
  end
end

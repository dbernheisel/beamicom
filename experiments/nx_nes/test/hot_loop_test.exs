defmodule NxNes.HotLoopTest do
  use ExUnit.Case, async: false
  alias Beamicom.NES.{CPU, Console}
  alias NxNes.HotLoop

  test "resident CPU loop agrees with interpreter for overflow, wraparound and aliased operands" do
    for {dst, src} <- [{31, 26}, {255, 255}],
        value <- [0, 1, 127, 128, 254, 255] do
      {media, cpu, bus} = fixture(dst, src, value)
      initial = HotLoop.load(media, cpu, bus)
      fun = EXLA.jit(&HotLoop.run/2, client: :host)
      # Feed output state back to the compiled function; never re-upload memory.
      Enum.reduce([1, 2, 19, 256], {initial, cpu, bus}, fn n, {state, cpu, bus} ->
        expected = Enum.reduce(1..(n * 6), {cpu, bus}, fn _, {cpu, bus} -> CPU.step(cpu, bus) end)
        assert NxNes.ElixirLoop.run(cpu, bus, n) == expected
        {cpu, bus} = expected
        state = fun.(state, HotLoop.scalar(n))
        assert %EXLA.Backend{} = state.ram.data
        assert Nx.to_binary(state.ram) == bus.ram
        assert Nx.to_binary(state.rom) == media

        for key <- [:a, :x, :y, :sp, :p, :pc, :cycles] do
          assert Nx.to_number(Map.fetch!(state, key)) == Map.fetch!(cpu, key)
        end

        {state, cpu, bus}
      end)
    end
  end

  test "unsupported code is rejected, rather than silently emulated as the specialized loop" do
    {media, cpu, bus} = fixture(31, 26, 0)
    assert_raise ArgumentError, fn -> HotLoop.load(media, %{cpu | pc: cpu.pc + 1}, bus) end
  end

  defp fixture(dst, src, value) do
    program = <<0xE6, dst, 0x18, 0xA5, dst, 0x65, src, 0x85, dst, 0x4C, 0, 0x80>>
    prg = program <> :binary.copy(<<0>>, 32768 - byte_size(program))
    media = <<"NES", 0x1A, 2, 0, 0::80>> <> prg
    c = Console.load_binary(media)
    ram = for i <- 0..2047, into: <<>>, do: <<rem(i + value, 256)>>
    cpu = %{c.cpu | pc: 0x8000, a: value, p: 0xED}
    {media, cpu, %{c.bus | ppu: nil, apu: nil, ram: ram}}
  end
end

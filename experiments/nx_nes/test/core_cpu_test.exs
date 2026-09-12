defmodule NxNes.CoreCPUTest do
  use ExUnit.Case, async: false
  alias NxNes.Core
  alias NxNes.Core.{CPU, Decode, Bus}
  alias Beamicom.NES.{Cart}

  test "every supported opcode matches native CPU registers, cycles, RAM, and WRAM" do
    fun = EXLA.jit(&CPU.step/2, client: :host)

    for opcode <- Decode.supported(),
        {a, x, y, sp, p} <- [
          {127, 255, 1, 255, 0xE5},
          {255, 3, 7, 0, 0x20},
          {0, 0, 0, 0xFD, 0x2F}
        ] do
      media = rom([opcode, 0x30, 0x60])
      {:ok, cart} = Cart.parse(media)
      ram = for i <- 0..2047, into: <<>>, do: <<rem(i * 13 + 7, 256)>>
      # Known zero-page indirect pointer, including indexed-zero-page wrap cases.
      ram = patch(ram, 0x30, <<0x40, 0x60>>)
      bus = %{Beamicom.NES.Bus.new(cart) | ram: ram}
      cpu = %Beamicom.NES.CPU{pc: 0x8000, a: a, x: x, y: y, sp: sp, p: p, cycles: 7}
      {:ok, s} = Core.load(media, pc: 0x8000)
      s = %{s | ram: resident_bytes(ram)}

      s =
        Enum.reduce([a: a, x: x, y: y, sp: sp, p: p], s, fn {k, v}, s ->
          Map.put(s, k, scalar(v))
        end)

      {expected, bus} = Beamicom.NES.CPU.step(cpu, bus)
      actual = fun.(s, Nx.tensor(1000, type: :s64))
      # Some indirect random pointers resolve to a device. Those must stop,
      # never silently return the native headless bus's unmapped zero.
      if Core.stop(actual) in [:device_read, :device_write] do
        assert Core.cpu(actual) == Core.cpu(s)
        assert Nx.to_binary(actual.ram) == ram
      else
        assert Core.stop(actual) == :running

        assert Core.cpu(actual) ==
                 Map.take(Map.from_struct(expected), [:a, :x, :y, :sp, :p, :pc, :cycles]),
               "opcode #{Integer.to_string(opcode, 16)}"

        assert Nx.to_binary(actual.ram) == bus.ram
        expected_wram = for addr <- 0x6000..0x7FFF, into: <<>>, do: <<Map.get(bus.wram, addr, 0)>>
        assert Nx.to_binary(actual.wram) == expected_wram
        assert Nx.to_binary(actual.prg) == cart.prg_rom
      end
    end
  end

  test "all nestest golden trace rows match across resident batches and explicit APU barriers" do
    media = File.read!("../../beamicom/test/support/fixtures/nestest.nes")
    {:ok, s} = Core.load(media, pc: 0xC000)

    rows =
      File.read!("../../beamicom/test/support/fixtures/nestest.log")
      |> String.split("\n", trim: true)
      |> Enum.map(fn line ->
        [_, pc, a, x, y, p, sp, cyc] =
          Regex.run(
            ~r/^([0-9A-F]{4}).*A:([0-9A-F]{2}) X:([0-9A-F]{2}) Y:([0-9A-F]{2}) P:([0-9A-F]{2}) SP:([0-9A-F]{2}).*CYC:(\d+)/,
            line
          )

        Enum.map([pc, a, x, y, p, sp], &String.to_integer(&1, 16)) ++ [String.to_integer(cyc)]
      end)

    fun = EXLA.jit(&CPU.trace/2, client: :host)

    loop = fn rec, s, rows, apu ->
      if rows == [] do
        s
      else
        {s, trace, count} = fun.(s, scalar(min(length(rows), 1024)))
        n = Nx.to_number(count)
        assert Nx.to_flat_list(trace) |> Enum.chunk_every(7) |> Enum.take(n) == Enum.take(rows, n)

        {s, apu} =
          case Core.stop(s) do
            :running ->
              assert(n > 0)
              {s, apu}

            :device_write ->
              addr = Nx.to_number(s.event_addr)
              assert addr in 0x4000..0x4017
              {Core.respond(s), Beamicom.NES.APU.write(apu, addr, Nx.to_number(s.event_value))}
          end

        rec.(rec, s, Enum.drop(rows, n), apu)
      end
    end

    final = loop.(loop, s, rows, Beamicom.NES.APU.new())
    assert Nx.to_number(final.cycles) == 26560
  end

  test "deadline rollback, exact boundary, continuation, and instruction budget" do
    {:ok, s} = Core.load(rom([0xA9, 0x42, 0x85, 0x10, 0xE8, 0x4C, 0, 0x80]), pc: 0x8000)
    fun = EXLA.jit(&CPU.run/3, client: :host)
    {a, n} = fun.(s, Nx.tensor(8, type: :s64), scalar(100))
    assert Core.stop(a) == :deadline
    assert Nx.to_number(n) == 0
    assert Core.cpu(a) == Core.cpu(s)
    {b, n} = fun.(a, Nx.tensor(9, type: :s64), scalar(100))
    assert Core.stop(b) == :deadline
    assert Nx.to_number(n) == 1
    assert Nx.to_number(b.a) == 0x42
    {c, n} = fun.(b, Nx.tensor(100, type: :s64), scalar(2))
    assert Core.stop(c) == :instruction_limit
    assert Nx.to_number(n) == 2
    assert :binary.at(Nx.to_binary(c.ram), 0x10) == 0x42
    assert Nx.to_number(c.x) == 1
    assert %EXLA.Backend{} = c.ram.data
    assert %EXLA.Backend{} = c.prg.data
  end

  test "MMIO read/write and RMW resume transactionally at the recorded cycle" do
    for code <- [[0xAD, 2, 0x20], [0x8D, 0, 0x20], [0xEE, 2, 0x20]] do
      {:ok, s} = Core.load(rom(code), pc: 0x8000)
      s = %{s | a: scalar(99)}
      fun = EXLA.jit(&CPU.run/3, client: :host)
      {bounded, zero} = fun.(s, Nx.tensor(8, type: :s64), scalar(1))
      assert Core.stop(bounded) == :deadline
      assert Nx.to_number(zero) == 0
      assert Core.cpu(bounded) == Core.cpu(s)
      {stopped, n} = fun.(bounded, Nx.tensor(100, type: :s64), scalar(1))
      assert Nx.to_number(n) == 0
      assert Core.cpu(stopped) == Core.cpu(s)
      assert Nx.to_number(stopped.event_cycle) == if(hd(code) == 0xEE, do: 12, else: 10)
      resumed = Core.respond(stopped, 0x7F)
      {next, _} = fun.(resumed, Nx.tensor(100, type: :s64), scalar(1))

      next =
        if hd(code) == 0xEE do
          assert Core.stop(next) == :device_write
          assert Nx.to_number(next.event_value) == 0x80
          assert Core.cpu(next) == Core.cpu(s)
          {next, _} = fun.(Core.respond(next), Nx.tensor(100, type: :s64), scalar(1))
          next
        else
          next
        end

      assert Core.stop(next) == :instruction_limit
      assert Nx.to_number(next.pc) == 0x8003
      assert Nx.to_number(next.io_read_ready) == 0
      assert Nx.to_number(next.io_write_ready) == 0
      if hd(code) == 0xAD, do: assert(Nx.to_number(next.a) == 127)
    end
  end

  test "RAM mirroring, immutable ROM, NROM-128 mirroring, and controller shifting" do
    media = rom([0xEA], 16384)
    {:ok, s} = Core.load(media, pc: 0x8000)
    s = %{s | pad1: scalar(0b10100101)}
    write = EXLA.jit(&Bus.write/3, client: :host)
    read = EXLA.jit(&Bus.read/2, client: :host)
    s = write.(s, scalar(0x1801), scalar(77))
    {v, s} = read.(s, scalar(1))
    assert Nx.to_number(v) == 77
    {v, _} = read.(s, scalar(0xC000))
    assert Nx.to_number(v) == 0xEA
    original = Nx.to_binary(s.prg)
    s = write.(s, scalar(0x8000), scalar(0))
    assert Nx.to_binary(s.prg) == original
    s = write.(s, scalar(0x4016), scalar(1))
    {v, s} = read.(s, scalar(0x4016))
    assert Nx.to_number(v) == 1
    s = write.(s, scalar(0x4016), scalar(0))

    {bits, _} =
      Enum.map_reduce(1..10, s, fn _, s ->
        {v, s} = read.(s, scalar(0x4016))
        {Nx.to_number(v), s}
      end)

    assert bits == [1, 0, 1, 0, 0, 1, 0, 1, 1, 1]
  end

  test "NMI and IRQ stack/vector entry and deadline rollback" do
    {:ok, s} = Core.load(rom([0xEA]), pc: 0x8123)
    s = %{s | p: scalar(0x20)}
    fun = EXLA.jit(&CPU.interrupt/3, client: :host)

    for {kind, vector} <- [{1, 0xFFFA}, {2, 0xFFFE}] do
      next = fun.(s, scalar(kind), Nx.tensor(100, type: :s64))
      prg = Nx.to_binary(s.prg)

      assert Nx.to_number(next.pc) ==
               :binary.at(prg, vector - 0x8000) + 256 * :binary.at(prg, vector - 0x8000 + 1)

      assert Nx.to_number(next.cycles) == 14
      assert Nx.to_number(next.sp) == 0xFA
      ram = Nx.to_binary(next.ram)
      assert :binary.at(ram, 0x1FD) == 0x81
      assert :binary.at(ram, 0x1FC) == 0x23
      assert :binary.at(ram, 0x1FB) == 0x20
      stopped = fun.(s, scalar(kind), Nx.tensor(13, type: :s64))
      assert Core.stop(stopped) == :deadline
      assert Nx.to_binary(stopped.ram) == Nx.to_binary(s.ram)
    end

    masked = fun.(%{s | p: scalar(0x24)}, scalar(2), Nx.tensor(100, type: :s64))
    assert Nx.to_number(masked.cycles) == 7
  end

  test "unsupported mapper/opcode stops explicitly" do
    media = rom([0x02])
    {:ok, s} = Core.load(media, pc: 0x8000)
    {next, n} = EXLA.jit(&CPU.run/3, client: :host).(s, Nx.tensor(100, type: :s64), scalar(1))
    assert Core.stop(next) == :unsupported_opcode
    assert Nx.to_number(n) == 0
    assert Core.cpu(next) == Core.cpu(s)
    assert {:error, {:unsupported_mapper, 1}} = Core.load(patch(media, 6, <<0x10>>))
  end

  defp scalar(n), do: Nx.tensor(n, type: :s32) |> NxNes.Batch.resident()
  defp resident_bytes(b), do: Nx.from_binary(b, :u8) |> NxNes.Batch.resident()

  defp patch(binary, offset, bytes) do
    size = byte_size(bytes)
    <<before::binary-size(^offset), _::binary-size(^size), after_::binary>> = binary
    before <> bytes <> after_
  end

  defp rom(code, size \\ 32768) do
    prg = :binary.copy(<<0xEA>>, size) |> patch(0, :erlang.list_to_binary(code))

    <<"NES", 0x1A, div(size, 16384), 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>> <>
      prg <> :binary.copy(<<0>>, 8192)
  end
end

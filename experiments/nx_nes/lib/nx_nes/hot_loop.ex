defmodule NxNes.HotLoop do
  @moduledoc """
  Feasibility kernel for a validated INC zp / CLC / LDA zp / ADC zp /
  STA zp / JMP loop. This is CPU-only: it does NOT emulate PPU/APU/interrupts.
  The full media, CPU RAM and cartridge RAM remain EXLA host buffers between calls.
  No ROM content is baked into the compiled function; operand bytes are read from
  the resident ROM. The caller validates the instruction shape before compiling.
  """
  import Nx.Defn

  def load(media, cpu, bus) do
    alias Beamicom.NES.{Bus, Cart}
    {:ok, cart} = Cart.parse(media)
    {prg_start, _} = :binary.match(media, cart.prg_rom)
    # This probe supports the observed ROM-backed entry, not MMC5 RAM windows.
    if cpu.pc < 0x8000 or bus.mapper_state.prg_ram_windows != 0,
      do: raise(ArgumentError, "probe requires a ROM-backed loop")

    offset = elem(bus.prg_banks, div(cpu.pc - 0x8000, 0x2000)) + rem(cpu.pc, 0x2000)
    bytes = for a <- cpu.pc..(cpu.pc + 11), do: Bus.peek(bus, a)

    case bytes do
      [0xE6, dst, 0x18, 0xA5, dst, 0x65, _src, 0x85, dst, 0x4C, lo, hi]
      when lo + hi * 256 == cpu.pc ->
        :ok

      _ ->
        raise ArgumentError, "entry does not match the supported six-instruction loop"
    end

    if rem(cpu.pc, 0x2000) + 12 > 0x2000,
      do: raise(ArgumentError, "probe cannot cross a bank window")

    wram = for a <- 0..65535, into: <<>>, do: <<Map.get(bus.wram, a, 0)>>

    state = %{
      rom: bytes(media),
      ram: bytes(bus.ram),
      wram: bytes(wram),
      a: scalar(cpu.a),
      x: scalar(cpu.x),
      y: scalar(cpu.y),
      sp: scalar(cpu.sp),
      pc: scalar(cpu.pc),
      p: scalar(cpu.p),
      cycles: scalar(cpu.cycles),
      code_offset: scalar(prg_start + offset)
    }

    Nx.backend_copy(state, {EXLA.Backend, client: :host})
  end

  def scalar(n), do: Nx.tensor(n, type: :s64, backend: Nx.BinaryBackend)
  defp bytes(b), do: Nx.from_binary(b, :u8, backend: Nx.BinaryBackend)

  defn run(state, iterations) do
    {state, _, _} =
      while {state, n = iterations, zero = Nx.tensor(0, type: :s64)}, n > zero do
        {iteration(state), n - 1, zero}
      end

    state
  end

  defnp iteration(s) do
    # Runtime ROM operands: use dynamic scalar indexing, not host reads.
    dst = Nx.as_type(s.rom[s.code_offset + 1], :s64)
    src = Nx.as_type(s.rom[s.code_offset + 6], :s64)
    incremented = Nx.bitwise_and(Nx.as_type(s.ram[dst], :s64) + 1, 255)
    ram = Nx.put_slice(s.ram, [dst], Nx.reshape(Nx.as_type(incremented, :u8), {1}))
    operand = Nx.as_type(ram[src], :s64)
    sum = incremented + operand
    result = Nx.bitwise_and(sum, 255)

    overflow =
      Nx.bitwise_and(
        Nx.bitwise_and(Nx.bitwise_xor(incremented, result), Nx.bitwise_xor(operand, result)),
        128
      ) != 0

    # INC/CLC/LDA flags are overwritten by ADC; JMP and STA do not change them.
    p = Nx.bitwise_or(Nx.bitwise_and(s.p, 60), Nx.bitwise_and(result, 128))
    p = Nx.bitwise_or(p, Nx.select(result == 0, 2, 0))
    p = Nx.bitwise_or(p, Nx.select(sum > 255, 1, 0))
    p = Nx.bitwise_or(p, Nx.select(overflow, 64, 0))
    ram = Nx.put_slice(ram, [dst], Nx.reshape(Nx.as_type(result, :u8), {1}))
    %{s | ram: ram, a: result, p: p, cycles: s.cycles + 19}
  end
end

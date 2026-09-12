defmodule NxNes.Core do
  @moduledoc "Optional resident Nx NES CPU/bus prototype. The production Beamicom.NES core stays native Elixir."
  alias Beamicom.NES.Cart

  def load(media, opts \\ []) do
    with {:ok, cart} <- Cart.parse(media) do
      cond do
        cart.mapper != 0 -> {:error, {:unsupported_mapper, cart.mapper}}
        byte_size(cart.chr_rom) not in [0, 8192] -> {:error, :unsupported_nrom_chr_size}
        byte_size(cart.prg_rom) not in [16384, 32768] -> {:error, :unsupported_nrom_prg_size}
        cart.prg_ram_size + cart.prg_nvram_size > 8192 -> {:error, :unsupported_nrom_ram_size}
        true -> {:ok, state(cart, opts)}
      end
    end
  end

  defp state(cart, opts) do
    mask = byte_size(cart.prg_rom) - 1
    lo = :binary.at(cart.prg_rom, Bitwise.band(0x7FFC, mask))
    hi = :binary.at(cart.prg_rom, Bitwise.band(0x7FFD, mask))

    ints = %{
      a: 0,
      x: 0,
      y: 0,
      sp: 0xFD,
      p: 0x24,
      pc: Keyword.get(opts, :pc, lo + 256 * hi),
      prg_mask: mask,
      pad1: 0,
      pad2: 0,
      pad1_index: 0,
      pad2_index: 0,
      strobe: 0,
      reason: 0,
      event_addr: 0,
      event_value: 0,
      opcode: 0,
      io_read_ready: 0,
      io_read_addr: 0,
      io_read_value: 0,
      io_write_ready: 0,
      io_write_addr: 0
    }

    s = Map.new(ints, fn {k, v} -> {k, Nx.tensor(v, type: :s32, backend: Nx.BinaryBackend)} end)
    chr = if cart.chr_rom == <<>>, do: :binary.copy(<<0>>, 8192), else: cart.chr_rom

    Map.merge(s, %{
      cycles: Nx.tensor(7, type: :s64, backend: Nx.BinaryBackend),
      event_cycle: Nx.tensor(0, type: :s64, backend: Nx.BinaryBackend),
      ram: Nx.from_binary(:binary.copy(<<0>>, 2048), :u8),
      wram: Nx.from_binary(:binary.copy(<<0>>, 8192), :u8),
      prg: Nx.from_binary(cart.prg_rom, :u8),
      chr: Nx.from_binary(chr, :u8)
    })
    |> Nx.backend_copy(Keyword.get(opts, :backend, {EXLA.Backend, client: :host}))
  end

  @doc "Supply a device read value or acknowledge a handled write, then retry the stopped instruction."
  def respond(s, value \\ 0) do
    reason = Nx.to_number(s.reason)

    if reason not in [2, 3] or not is_integer(value) or value < 0 or value > 255,
      do: raise(ArgumentError, "expected a device barrier and byte response")

    scalar = fn v -> Nx.add(Nx.multiply(s.reason, 0), v) end

    case reason do
      2 ->
        %{
          s
          | io_read_ready: scalar.(1),
            io_read_addr: s.event_addr,
            io_read_value: scalar.(value)
        }

      3 ->
        %{s | io_write_ready: scalar.(1), io_write_addr: s.event_addr}
    end
  end

  def cpu(s),
    do: Map.new([:a, :x, :y, :sp, :p, :pc, :cycles], &{&1, Nx.to_number(Map.fetch!(s, &1))})

  def stop(s),
    do:
      Map.fetch!(
        %{
          0 => :running,
          1 => :deadline,
          2 => :device_read,
          3 => :device_write,
          4 => :unsupported_opcode,
          5 => :instruction_limit,
          6 => :instruction_fetch
        },
        Nx.to_number(s.reason)
      )
end

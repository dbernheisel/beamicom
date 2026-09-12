defmodule NxNes.BlocksTest do
  use ExUnit.Case, async: false
  alias NxNes.Core
  alias NxNes.Core.{Blocks, CPU, Decode}

  defp rom(code) do
    <<"NES", 26, 1, 1, 0::size(80)>> <>
      :erlang.list_to_binary(code) <>
      :binary.copy(<<0>>, 16384 - length(code)) <>
      :binary.copy(<<0>>, 8192)
  end

  defp scalar(v), do: Nx.tensor(v, type: :s32)
  defp deadline(v), do: Nx.tensor(v, type: :s64)

  defp same(a, b) do
    for key <- Map.keys(a), do: assert(Nx.to_binary(a[key]) == Nx.to_binary(b[key]), "#{key}")
  end

  test "fused loop matches every state field at all partial-block deadlines and limits" do
    media = rom([0xE6, 0x10, 0x18, 0xA5, 0x10, 0x65, 0x11, 0x85, 0x10, 0x4C, 0, 0x80])
    {:ok, block} = Blocks.analyze(media, 0x8000)
    assert block.count == 6
    assert block.cycles == 19
    {:ok, s} = Core.load(media, pc: 0x8000)
    fused = EXLA.jit(fn s, d, l -> Blocks.run(s, d, l, block: block) end, client: :host)
    generic = EXLA.jit(&CPU.run/3, client: :host)

    for d <- 7..65, l <- [1, 5, 6, 7, 12, 30] do
      {a, n, _} = fused.(s, deadline(d), scalar(l))
      {b, m} = generic.(s, deadline(d), scalar(l))
      same(a, b)
      assert Nx.to_number(n) == Nx.to_number(m)
    end

    {_, _, hits} = fused.(s, deadline(1000), scalar(60))
    assert Nx.to_number(hits) == 10
  end

  @tag timeout: 180_000
  test "every accepted opcode agrees with native including flags and RAM mirrors" do
    for opcode <- Decode.supported() do
      media = rom([opcode, 0x10, 0x08])

      case Blocks.analyze(media, 0x8000, 1) do
        {:error, :no_compilable_instructions} ->
          :ok

        {:ok, block} ->
          {:ok, cart} = Beamicom.NES.Cart.parse(media)
          fun = EXLA.jit(fn s, d, l -> Blocks.run(s, d, l, block: block) end, client: :host)

          for {a, x, y, sp, p} <- [
                {127, 255, 1, 0, 0xE5},
                {255, 3, 7, 255, 0x20},
                {0, 0, 0, 0xFD, 0x2F}
              ] do
            ram = for i <- 0..2047, into: <<>>, do: <<rem(i * 13 + 7, 256)>>
            bus = %{Beamicom.NES.Bus.new(cart) | ram: ram}
            cpu = %Beamicom.NES.CPU{pc: 0x8000, a: a, x: x, y: y, sp: sp, p: p, cycles: 7}
            {expected, bus} = Beamicom.NES.CPU.step(cpu, bus)
            {:ok, s} = Core.load(media, pc: 0x8000)

            s =
              Enum.reduce([a: a, x: x, y: y, sp: sp, p: p], s, fn {k, v}, s ->
                Map.put(s, k, scalar(v))
              end)

            s = %{s | ram: Nx.from_binary(ram, :u8)}
            {actual, n, hits} = fun.(s, deadline(1000), scalar(1))
            assert Nx.to_number(n) == 1
            assert Nx.to_number(hits) == 1

            assert Core.cpu(actual) ==
                     Map.take(Map.from_struct(expected), [:a, :x, :y, :sp, :p, :pc, :cycles]),
                   "opcode #{opcode}"

            assert Nx.to_binary(actual.ram) == bus.ram
          end
      end
    end
  end

  test "changed ROM, MMIO and pending read responses go through generic interpreter" do
    media = rom([0xA9, 42, 0x85, 0x10, 0x8D, 0, 0x20])
    {:ok, block} = Blocks.analyze(media, 0x8000)
    assert block.count == 2
    fused = EXLA.jit(fn s, d, l -> Blocks.run(s, d, l, block: block) end, client: :host)
    generic = EXLA.jit(&CPU.run/3, client: :host)

    for media <- [media, rom([0xA9, 99, 0x85, 0x10, 0x8D, 0, 0x20])] do
      {:ok, s} = Core.load(media, pc: 0x8000)
      {a, n, hits} = fused.(s, deadline(1000), scalar(10))
      {b, m} = generic.(s, deadline(1000), scalar(10))
      same(a, b)
      assert Nx.to_number(n) == Nx.to_number(m)
      assert Core.stop(a) == :device_write
      assert Nx.to_number(hits) == if(Nx.to_number(a.a) == 42, do: 1, else: 0)
      {a, _, _} = fused.(Core.respond(a), deadline(1000), scalar(1))
      {b, _} = generic.(Core.respond(b), deadline(1000), scalar(1))
      same(a, b)
    end

    {:ok, s} = Core.load(media, pc: 0x8000)
    s = %{s | io_read_ready: scalar(1), io_read_addr: scalar(0x8001), io_read_value: scalar(17)}
    {a, _, hits} = fused.(s, deadline(1000), scalar(2))
    {b, _} = generic.(s, deadline(1000), scalar(2))
    same(a, b)
    assert Nx.to_number(hits) == 0
  end

  test "RAM aliases forward stores and overflow survives fusion" do
    media =
      rom([
        0xA9,
        255,
        0x85,
        0x10,
        0xE6,
        0x10,
        0xAD,
        0x10,
        0x08,
        0x69,
        127,
        0x69,
        1,
        0x8D,
        0x10,
        0x18,
        0x4C,
        0,
        0x80
      ])

    {:ok, block} = Blocks.analyze(media, 0x8000)
    {:ok, s} = Core.load(media, pc: 0x8000)
    fused = EXLA.jit(fn s, d, l -> Blocks.run(s, d, l, block: block) end, client: :host)
    {a, _, hits} = fused.(s, deadline(10000), scalar(80))
    {b, _} = EXLA.jit(&CPU.run/3, client: :host).(s, deadline(10000), scalar(80))
    same(a, b)
    assert Nx.to_number(hits) == 10
  end
end

alias NxNes.Core
alias NxNes.Core.CPU
alias Beamicom.NES.{Cart, Bus}
media = File.read!("../../beamicom/test/support/fixtures/nestest.nes")
{:ok, cart} = Cart.parse(media)
{:ok, initial} = Core.load(media, pc: 0xC000)
native_initial = %Beamicom.NES.CPU{pc: 0xC000, cycles: 7}

reference = fn ->
  Enum.reduce(1..8991, {native_initial, Bus.new(cart)}, fn _, {c, b} ->
    Beamicom.NES.CPU.step(c, b)
  end)
end

{expected, expected_bus} = reference.()

{compile, fun} =
  :timer.tc(fn ->
    EXLA.compile(
      &CPU.run/3,
      [Nx.to_template(initial), Nx.template({}, :s64), Nx.template({}, :s32)],
      client: :host
    )
  end)

IO.puts("CPU run compilation: #{compile / 1000} ms")

variants =
  for horizon <- [114, 7457, 29830] do
    run = fn ->
      loop = fn rec, s, left, deadline, calls, barriers, apu ->
        if left == 0 do
          {s, calls, barriers}
        else
          {s, n} = fun.(s, Nx.tensor(deadline, type: :s64), Nx.tensor(left, type: :s32))
          n = Nx.to_number(n)

          case Core.stop(s) do
            :deadline ->
              rec.(rec, s, left - n, deadline + horizon, calls + 1, barriers, apu)

            :instruction_limit ->
              {s, calls + 1, barriers}

            :device_write ->
              addr = Nx.to_number(s.event_addr)
              value = Nx.to_number(s.event_value)
              if addr not in 0x4000..0x4017, do: raise("unexpected device")
              apu = Beamicom.NES.APU.write(apu, addr, value)
              rec.(rec, Core.respond(s), left - n, deadline, calls + 1, barriers + 1, apu)

            reason ->
              raise("unexpected stop: #{reason}")
          end
        end
      end

      result = {s, _, _} = loop.(loop, initial, 8991, 7 + horizon, 0, 0, Beamicom.NES.APU.new())
      # Synchronization is included; full state correctness is checked outside timing.
      Nx.to_number(s.cycles)
      result
    end

    {s, calls, barriers} = run.()

    if Core.cpu(s) != Map.take(Map.from_struct(expected), [:a, :x, :y, :sp, :p, :pc, :cycles]),
      do: raise("CPU differs")

    if Nx.to_binary(s.ram) != expected_bus.ram, do: raise("RAM differs")
    {horizon, run, calls, barriers}
  end

all = [{:native, reference, 0, 0} | variants]
Enum.each(all, fn {_, f, _, _} -> f.() end)

times =
  Enum.reduce(0..4, %{}, fn round, acc ->
    {a, b} = Enum.split(all, rem(round, length(all)))

    Enum.reduce(b ++ a, acc, fn {key, f, _, _}, acc ->
      :erlang.garbage_collect()
      {us, _} = :timer.tc(f)
      Map.update(acc, to_string(key), [us], &(&1 ++ [us]))
    end)
  end)

result = %{
  scope:
    "8991 nestest instructions, headless CPU/bus, conservative synthetic device horizons; 5 APU writes handled explicitly outside Nx",
  instructions: 8991,
  compile_ms: compile / 1000,
  diagnostic_sequential: System.get_env("NX_APU_FORCE_SEQUENTIAL") != nil,
  timings_us: times,
  variants:
    Enum.map(variants, fn {h, _, calls, barriers} ->
      %{horizon: h, calls: calls, device_barriers: barriers}
    end),
  correctness:
    "final registers/cycles and RAM exact against native CPU; full trace validated separately"
}

File.write!(
  List.first(System.argv()) || "results/cpu_bench.json",
  IO.iodata_to_binary(:json.encode(result)) <> "\n"
)

IO.inspect(result)

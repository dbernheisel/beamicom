alias NxNes.Core
alias NxNes.Core.CPU
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

{compile, fun} =
  :timer.tc(fn ->
    EXLA.compile(&CPU.trace/2, [Nx.to_template(s), Nx.template({}, :s32)], client: :host)
  end)

IO.puts("trace compile #{compile / 1000} ms")
# Device writes in the test's epilogue are handled by the retained Elixir APU.
loop = fn rec, s, expected, offset, apu, barriers ->
  if expected == [] do
    {s, barriers}
  else
    limit = min(length(expected), 1024)
    {s, trace, n} = fun.(s, Nx.tensor(limit, type: :s32))
    n = Nx.to_number(n)
    got = Nx.to_flat_list(trace) |> Enum.chunk_every(7) |> Enum.take(n)

    Enum.zip(got, Enum.take(expected, n))
    |> Enum.with_index(offset + 1)
    |> Enum.each(fn {{a, e}, line} ->
      if a != e, do: raise("nestest line #{line}: #{inspect(a)} != #{inspect(e)}")
    end)

    {s, apu, barriers} =
      case Core.stop(s) do
        :running ->
          {s, apu, barriers}

        :device_write ->
          addr = Nx.to_number(s.event_addr)
          value = Nx.to_number(s.event_value)
          if addr not in 0x4000..0x4017, do: raise("unexpected device write")
          apu = Beamicom.NES.APU.write(apu, addr, value)
          {Core.respond(s), apu, barriers + 1}

        reason ->
          raise("stopped #{reason} at #{inspect(Core.cpu(s))}")
      end

    IO.puts("verified #{offset + n} rows")
    rec.(rec, s, Enum.drop(expected, n), offset + n, apu, barriers)
  end
end

{us, {final, barriers}} = :timer.tc(fn -> loop.(loop, s, rows, 0, Beamicom.NES.APU.new(), 0) end)

result = %{
  rows: length(rows),
  compile_ms: compile / 1000,
  trace_ms: us / 1000,
  device_barriers: barriers,
  stop: Core.stop(final),
  cpu: Core.cpu(final),
  ram_sha: Base.encode16(:crypto.hash(:sha256, Nx.to_binary(final.ram)), case: :lower)
}

File.write!("results/cpu_nestest.json", IO.iodata_to_binary(:json.encode(result)) <> "\n")
IO.inspect(result)

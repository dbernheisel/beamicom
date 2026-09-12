alias NxNes.BranchlessCPU
alias NxNes.Core
alias NxNes.Core.CPU

{opts, args} = OptionParser.parse!(System.argv(), strict: [instructions: :integer])
instructions = Keyword.get(opts, :instructions, 100_000)

program = <<
  0x18,
  0xA2,
  0x02,
  0xA5,
  0x20,
  0x29,
  0x0F,
  0x65,
  0x21,
  0x85,
  0x22,
  0xE6,
  0x20,
  0xCA,
  0xD0,
  0x00,
  0x4C,
  0x00,
  0x80
>>

prg = :binary.copy(<<0xEA>>, 32_768)
prg = program <> binary_part(prg, byte_size(program), 32_768 - byte_size(program))
media = <<"NES", 26, 2, 0, 0::80>> <> prg
flat_rom = :binary.copy(<<0>>, 32_768) <> prg
ram_binary = :binary.copy(<<0>>, 0x20) <> <<1, 2>> <> :binary.copy(<<0>>, 2048 - 0x22)
backend = {EXLA.Backend, client: :host}
ram_host = Nx.from_binary(ram_binary, :u8)
registers = Nx.tensor([0, 0, 0, 0xFD, 0x24, 0x8000, 0, 0], type: :s64)
rom = Nx.from_binary(flat_rom, :u8)

{:ok, generic} = Core.load(media, pc: 0x8000)

generic =
  %{generic | ram: ram_host, p: Nx.tensor(0x24, type: :s32), cycles: Nx.tensor(0, type: :s64)}
  |> Nx.backend_copy(backend)

registers = Nx.backend_copy(registers, backend)
rom = Nx.backend_copy(rom, backend)

{branchless_compile_us, branchless} =
  :timer.tc(fn ->
    EXLA.compile(
      &BranchlessCPU.run/4,
      [
        Nx.to_template(registers),
        ram_host |> Nx.donatable() |> Nx.to_template(),
        Nx.to_template(rom),
        Nx.template({}, :s32)
      ],
      client: :host
    )
  end)

{generic_compile_us, generic_run} =
  :timer.tc(fn ->
    EXLA.compile(
      &CPU.run/3,
      [Nx.to_template(generic), Nx.template({}, :s64), Nx.template({}, :s32)],
      client: :host
    )
  end)

limit = Nx.tensor(instructions, type: :s32)
expected_input_ram = Nx.backend_copy(ram_host, backend)
input_pointer = Nx.to_pointer(expected_input_ram).address

{expected_registers, expected_ram} =
  branchless.(registers, Nx.donatable(expected_input_ram), rom, limit)

if Nx.to_pointer(expected_ram).address != input_pointer,
  do: raise("donated RAM buffer was not reused")

{expected_generic, count} =
  generic_run.(generic, Nx.tensor(1_152_921_504_606_846_976, type: :s64), limit)

if Nx.to_number(count) != instructions, do: raise("generic CPU stopped early")

expected = Nx.to_flat_list(expected_registers)

actual = [
  Nx.to_number(expected_generic.a),
  Nx.to_number(expected_generic.x),
  Nx.to_number(expected_generic.y),
  Nx.to_number(expected_generic.sp),
  Nx.to_number(expected_generic.p),
  Nx.to_number(expected_generic.pc),
  Nx.to_number(expected_generic.cycles),
  0
]

if expected != actual, do: raise("register mismatch: #{inspect(expected)} != #{inspect(actual)}")
if Nx.to_binary(expected_ram) != Nx.to_binary(expected_generic.ram), do: raise("RAM mismatch")

measure = fn fun, sync ->
  for _ <- 1..7 do
    :erlang.garbage_collect()
    {us, result} = :timer.tc(fun)
    sync.(result)
    us
  end
end

ram_seeds = for _ <- 1..7, do: Nx.backend_copy(ram_host, backend)

branchless_times =
  Enum.map(ram_seeds, fn ram ->
    :erlang.garbage_collect()

    {us, {result, _ram}} =
      :timer.tc(fn -> branchless.(registers, Nx.donatable(ram), rom, limit) end)

    Nx.to_flat_list(result)
    us
  end)

generic_times =
  measure.(
    fn -> generic_run.(generic, Nx.tensor(1_152_921_504_606_846_976, type: :s64), limit) end,
    fn {s, _} -> Nx.to_number(s.cycles) end
  )

result = %{
  scope: "Ten-opcode synthetic NROM loop; one resident EXLA call per run",
  instructions: instructions,
  operations: ["ADC", "AND", "BNE", "CLC", "DEX", "INC", "JMP", "LDA", "LDX", "STA"],
  correctness: "registers, cycles, and 2 KiB RAM exactly match the complete CPU",
  donated_ram_pointer_reused: true,
  compile_ms: %{branchless: branchless_compile_us / 1000, generic: generic_compile_us / 1000},
  timings_us: %{branchless: branchless_times, generic: generic_times}
}

IO.inspect(result)

if output = List.first(args) do
  File.write!(output, IO.iodata_to_binary(:json.encode(result)) <> "\n")
end

defmodule BeamicomNx.NES.APUBlockRenderer do
  @moduledoc """
  Frame-block Nx renderer for the 2A03 and MMC5 audio channels.

  The native core supplies timestamped register operations while the oscillator
  and filter state remains resident on EXLA between calls.
  """

  alias BeamicomNx.NES.{APU, BlockAPU}
  @behaviour Beamicom.NES.APURenderer

  @capacity 128
  @compiled_key {__MODULE__, :compiled}

  @impl true
  def prepare(native_apu) do
    native_apu
    |> APU.pack()
    |> Nx.backend_copy({EXLA.Backend, client: :host})
  end

  @impl true
  def snapshot(state), do: Nx.backend_copy(state, Nx.BinaryBackend)
  @impl true
  def restore(state), do: Nx.backend_copy(state, {EXLA.Backend, client: :host})

  @impl true
  def render(state, events, cycles, dmc_samples) do
    if length(dmc_samples) > 1024, do: raise("DMC sample-level block exceeds capacity")

    {event_tensor, event_count} = BlockAPU.events(events, cycles, @capacity)
    dmc = Nx.tensor(dmc_samples ++ List.duplicate(0, 1024 - length(dmc_samples)), type: :s32)

    resident = fn tensor -> Nx.backend_copy(tensor, {EXLA.Backend, client: :host}) end

    args = [
      state,
      resident.(event_tensor),
      resident.(event_count),
      resident.(Nx.tensor(cycles, type: :s32)),
      resident.(dmc)
    ]

    {state, pcm, count, left, consumed} = apply(compiled(args), args)
    count = Nx.to_number(count)

    if Nx.to_number(left) != 0 or Nx.to_number(consumed) != length(events),
      do: raise("Nx APU block did not consume the complete frame")

    bytes = pcm |> Nx.to_binary() |> binary_part(0, count * 2)
    {count, bytes, state}
  end

  @impl true
  def supports_event?(addr, _value),
    do: addr in 0x4000..0x4013 or addr in [0x4015, 0x4017] or addr in 0x5000..0x5015

  defp compiled(args) do
    case :persistent_term.get(@compiled_key, nil) do
      nil ->
        fun =
          EXLA.compile(&BlockAPU.run/5, Enum.map(args, &Nx.to_template/1), client: :host)

        :persistent_term.put(@compiled_key, fun)
        fun

      fun ->
        fun
    end
  end
end

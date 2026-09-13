if Code.ensure_loaded?(Nx.Defn) and Code.ensure_loaded?(EXLA) do
  defmodule Beamicom.NES.Nx.APUBlockRenderer do
    @moduledoc """
    Frame-block Nx renderer for the 2A03, MMC5, and mapper expansion audio.

    The native core supplies timestamped register operations while the oscillator
    and filter state remains resident on EXLA between calls.
    """

    alias Beamicom.NES.Nx.{APU, BlockAPU}
    @behaviour Beamicom.NES.APURenderer

    @capacity 128
    @compiled_key {__MODULE__, :compiled}

    @impl true
    def prepare(native_apu) do
      state =
        native_apu
        |> APU.pack()
        |> Nx.backend_copy({EXLA.Backend, client: :host})

      # Compile while the console is loading. Scenic starts its audio player only
      # after load returns, so first-use EXLA compilation cannot starve the player
      # or make the runtime enqueue a catch-up burst.
      compiled([
        state,
        Nx.template({@capacity, 3}, :s32),
        Nx.template({}, :s32),
        Nx.template({}, :s32),
        Nx.template({1024}, :s32),
        Nx.template({1024}, :f64)
      ])

      state
    end

    @impl true
    def snapshot(state), do: Nx.backend_copy(state, Nx.BinaryBackend)
    @impl true
    def restore(state), do: Nx.backend_copy(state, {EXLA.Backend, client: :host})

    @impl true
    def render(state, events, cycles, sample_inputs) do
      if length(sample_inputs) > 1024, do: raise("sample-level block exceeds capacity")

      {dmc_samples, expansion_samples} = split_inputs(sample_inputs)

      {event_tensor, event_count} = BlockAPU.events(events, cycles, @capacity)
      dmc = Nx.tensor(dmc_samples ++ List.duplicate(0, 1024 - length(dmc_samples)), type: :s32)

      expansion =
        Nx.tensor(expansion_samples ++ List.duplicate(0.0, 1024 - length(expansion_samples)),
          type: :f64
        )

      resident = fn tensor -> Nx.backend_copy(tensor, {EXLA.Backend, client: :host}) end

      args = [
        state,
        resident.(event_tensor),
        resident.(event_count),
        resident.(Nx.tensor(cycles, type: :s32)),
        resident.(dmc),
        resident.(expansion)
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
            EXLA.compile(&BlockAPU.run/6, Enum.map(args, &Nx.to_template/1), client: :host)

          :persistent_term.put(@compiled_key, fun)
          fun

        fun ->
          fun
      end
    end

    defp split_inputs(inputs) do
      inputs
      |> Enum.map(fn
        {dmc, expansion} -> {dmc, expansion}
        dmc when is_integer(dmc) -> {dmc, 0.0}
      end)
      |> Enum.unzip()
    end
  end
end

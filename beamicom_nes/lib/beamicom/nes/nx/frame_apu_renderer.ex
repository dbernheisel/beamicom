if Code.ensure_loaded?(Nx.Defn) do
  defmodule Beamicom.NES.Nx.FrameAPURenderer do
    @moduledoc """
    Fixed-frame 48 kHz renderer for 2A03, DMC, and MMC5 audio.

    CPU-visible DMC state remains native. Its DAC level and mapper expansion
    level are captured at 192 kHz, mixed with resident Nx oscillator state, and
    decimated by a 33-tap windowed-sinc convolution. Every call returns exactly
    800 signed samples; the short NTSC-frame tail is held before decimation.
    """

    alias Beamicom.NES.Nx.{APU, BlockAPU, FrameAPUExecutable, FrameAudioMath}
    @behaviour Beamicom.NES.APURenderer

    @capacity 128
    @sample_capacity 4096
    @compiled_key {__MODULE__, :compiled}

    def sample_rate, do: 48_000
    def sample_input_rate, do: 192_000

    @impl true
    def prepare(native_apu) do
      state =
        {
          native_apu |> APU.pack() |> Nx.backend_copy(backend()),
          FrameAudioMath.sinc_kernel() |> Nx.backend_copy(backend())
        }
        |> Nx.donatable()

      compiled([
        state,
        Nx.template({@capacity, 3}, :s32),
        Nx.template({}, :s32),
        Nx.template({}, :s32),
        Nx.template({@sample_capacity}, :s32),
        Nx.template({@sample_capacity}, :f64)
      ])

      state
    end

    @impl true
    def render(state, events, cycles, sample_inputs) do
      if length(sample_inputs) > @sample_capacity,
        do: raise("192 kHz sample-level block exceeds capacity")

      {dmc_samples, expansion_samples} = split_inputs(sample_inputs)
      {event_tensor, event_count} = BlockAPU.events(events, cycles, @capacity)

      dmc =
        Nx.tensor(dmc_samples ++ List.duplicate(0, @sample_capacity - length(dmc_samples)),
          type: :s32
        )

      expansion =
        Nx.tensor(
          expansion_samples ++ List.duplicate(0.0, @sample_capacity - length(expansion_samples)),
          type: :f64
        )

      resident = fn tensor -> Nx.backend_copy(tensor, backend()) end

      args = [
        state,
        resident.(event_tensor),
        resident.(event_count),
        resident.(Nx.tensor(cycles, type: :s32)),
        resident.(dmc),
        resident.(expansion)
      ]

      {state, pcm, count, left, consumed, input_count} = apply(compiled(args), args)

      if Nx.to_number(left) != 0 or Nx.to_number(consumed) != length(events),
        do: raise("Nx 48 kHz APU frame did not consume the complete CPU timeline")

      if Nx.to_number(input_count) != length(sample_inputs),
        do: raise("Nx 48 kHz APU frame did not consume the complete DMC level stream")

      count = Nx.to_number(count)
      {count, Nx.to_binary(pcm), Nx.donatable(state)}
    end

    @impl true
    def supports_event?(addr, _value),
      do: addr in 0x4000..0x4013 or addr in [0x4015, 0x4017] or addr in 0x5000..0x5015

    @impl true
    def snapshot(state), do: Nx.backend_copy(state, Nx.BinaryBackend)

    @impl true
    def restore(state), do: state |> Nx.backend_copy(backend()) |> Nx.donatable()

    defp compiled(args) do
      key = {@compiled_key, Beamicom.NES.Nx.compiler_options()}

      case :persistent_term.get(key, nil) do
        nil ->
          fun =
            FrameAPUExecutable.loaded() ||
              Beamicom.NES.Nx.compile(&FrameAPUExecutable.run/6, args)

          :persistent_term.put(key, fun)
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

    defp backend, do: Beamicom.NES.Nx.backend()
  end
end

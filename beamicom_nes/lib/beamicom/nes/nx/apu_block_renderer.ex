if Code.ensure_loaded?(Nx.Defn) do
  defmodule Beamicom.NES.Nx.APUBlockRenderer do
    @moduledoc """
    Frame-block Nx renderer for the 2A03, MMC5, and mapper expansion audio.

    The native core supplies timestamped register operations while the oscillator
    and filter state remains resident on the configured Nx backend between calls.
    Sample phase, nonlinear mixer values, and filter recurrence use signed Q30
    fixed point so the block graph contains no floating-point tensors. The GPU
    produces a parallel raw sample block; the small recurrent output filter runs
    on the host, where its strict sample dependency is inexpensive.
    """

    alias Beamicom.NES.Nx.{APU, BlockAPU}
    @behaviour Beamicom.NES.APURenderer

    @capacity 128
    @fixed_scale Bitwise.bsl(1, 30)
    @hp90_fixed round(0.987340 * @fixed_scale)
    @lp8k_fixed round(0.532680 * @fixed_scale)
    @compiled_key {__MODULE__, :compiled}

    @impl true
    def prepare(native_apu) do
      apu =
        native_apu
        |> APU.pack_fixed()
        |> Nx.backend_copy(backend())
        |> Nx.donatable()

      # Compile while the console is loading. Scenic starts its audio player only
      # after load returns, so first-use Nx compilation cannot starve the player
      # or make the runtime enqueue a catch-up burst.
      compiled([
        apu,
        Nx.template({@capacity, 3}, :s32),
        Nx.template({}, :s32),
        Nx.template({}, :s32),
        Nx.template({1024}, :s32),
        Nx.template({1024}, :s64)
      ])

      %{
        apu: apu,
        filter:
          {APU.to_fixed(native_apu.f_hp), APU.to_fixed(native_apu.f_hp_x),
           APU.to_fixed(native_apu.f_lp)}
      }
    end

    @impl true
    def snapshot(%{apu: apu} = state), do: %{state | apu: Nx.backend_copy(apu, Nx.BinaryBackend)}

    @impl true
    def restore(%{apu: apu} = state),
      do: %{state | apu: apu |> Nx.backend_copy(backend()) |> Nx.donatable()}

    @impl true
    def render(%{apu: apu, filter: filter}, events, cycles, sample_inputs) do
      if length(sample_inputs) > 1024, do: raise("sample-level block exceeds capacity")

      {dmc_samples, expansion_samples} = split_inputs(sample_inputs)

      {event_tensor, event_count} = BlockAPU.events(events, cycles, @capacity)
      dmc = Nx.tensor(dmc_samples ++ List.duplicate(0, 1024 - length(dmc_samples)), type: :s32)

      expansion =
        expansion_samples
        |> Enum.map(&APU.to_fixed/1)
        |> Kernel.++(List.duplicate(0, 1024 - length(expansion_samples)))
        |> Nx.tensor(type: :s64)

      resident = fn tensor -> Nx.backend_copy(tensor, backend()) end

      args = [
        apu,
        resident.(event_tensor),
        resident.(event_count),
        resident.(Nx.tensor(cycles, type: :s32)),
        resident.(dmc),
        resident.(expansion)
      ]

      {apu, raw, count, left, consumed} = apply(compiled(args), args)
      count = Nx.to_number(count)

      if Nx.to_number(left) != 0 or Nx.to_number(consumed) != length(events),
        do: raise("Nx APU block did not consume the complete frame")

      raw = raw |> Nx.to_binary() |> binary_part(0, count * 8)
      {bytes, filter} = filter_pcm(raw, filter, [])
      {count, bytes, %{apu: Nx.donatable(apu), filter: filter}}
    end

    @impl true
    def supports_event?(addr, _value),
      do: addr in 0x4000..0x4013 or addr in [0x4015, 0x4017] or addr in 0x5000..0x5015

    defp compiled(args) do
      key = {@compiled_key, Beamicom.NES.Nx.compiler_options()}

      case :persistent_term.get(key, nil) do
        nil ->
          fun = Beamicom.NES.Nx.compile(&BlockAPU.run/6, args)

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

    defp filter_pcm(<<>>, filter, samples),
      do: {samples |> Enum.reverse() |> IO.iodata_to_binary(), filter}

    defp filter_pcm(<<x::signed-native-64, rest::binary>>, {hp, previous, lp}, samples) do
      hp = fixed_multiply(@hp90_fixed, hp + x - previous)
      lp = lp + fixed_multiply(@lp8k_fixed, hp - lp)
      sample = fixed_pcm(lp)
      filter_pcm(rest, {hp, x, lp}, [<<sample::signed-native-16>> | samples])
    end

    defp fixed_multiply(coefficient, value), do: fixed_divide(coefficient * value)
    defp fixed_pcm(value), do: (value * 32_767) |> fixed_divide() |> min(32_767) |> max(-32_768)

    defp fixed_divide(value) when value >= 0,
      do: div(value + div(@fixed_scale, 2), @fixed_scale)

    defp fixed_divide(value), do: div(value - div(@fixed_scale, 2), @fixed_scale)

    defp backend, do: Beamicom.NES.Nx.backend()
  end
end

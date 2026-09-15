if Code.ensure_loaded?(Nx.Defn) do
  defmodule Beamicom.SNES.Nx.DSPRenderer do
    @moduledoc "Compiled eight-voice SNES DSP synthesis and stereo mixing."

    import Bitwise, only: [&&&: 2, <<<: 2, >>>: 2, |||: 2]
    import Nx.Defn

    @capacity 1024
    @block_capacity 258
    @state_columns 25
    @compiled_key {__MODULE__, :synthesize_v1}
    @mix_key {__MODULE__, :mix_v2}

    def minimum_frames, do: 64
    def synthesis_minimum_frames, do: 4096

    def warmup do
      args = [
        zero({8, @state_columns}),
        zero({8, @block_capacity, 10}),
        zero({8, 3}),
        zero({3}),
        Nx.tensor(0, type: :s32) |> resident()
      ]

      compiled(args)

      mix_args = [zero({@capacity, 8}), zero({8, 2}), zero({2})]
      compiled_mix(mix_args)
      :ok
    end

    @doc "Mixes frame-major eight-voice samples in one compiled tensor operation."
    def render(sample_rows, {voice_controls, muted?, master_left, master_right}) do
      volumes =
        voice_controls
        |> Tuple.to_list()
        |> Enum.map(fn {_pitch, left, right} -> [left, right] end)
        |> Nx.tensor(type: :s32)
        |> resident()

      master =
        if(muted?, do: [0, 0], else: [master_left, master_right])
        |> Nx.tensor(type: :s32)
        |> resident()

      sample_rows
      |> Enum.chunk_every(@capacity)
      |> Enum.map(&render_mix_chunk(&1, volumes, master))
      |> IO.iodata_to_binary()
    end

    defn mix(samples, volumes, master) do
      samples = Nx.new_axis(samples, 2)
      channels = Nx.quotient(samples * volumes, 128) |> Nx.sum(axes: [1])
      channels = Nx.quotient(channels * master, 128)
      Nx.clip(channels, -32_768, 32_767) |> Nx.as_type(:s16)
    end

    @doc "Advances eight voices, decodes BRR blocks, and emits signed-16 stereo PCM."
    def render(voices, end_flags, ram, mixer, frames) do
      Enum.reduce(chunk_sizes(frames), {voices, end_flags, []}, fn count,
                                                                   {voices, flags, chunks} ->
        {voices, ended, pcm} = render_chunk(voices, ram, mixer, count)
        {voices, flags ||| ended, [pcm | chunks]}
      end)
      |> then(fn {voices, flags, chunks} ->
        {voices, flags, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
      end)
    end

    defn synthesize(state, blocks, controls, master, count) do
      pcm = Nx.broadcast(Nx.tensor(0, type: :s32), {@capacity, 2})
      cursor = Nx.broadcast(Nx.tensor(0, type: :s32), {8})
      ended = Nx.broadcast(Nx.tensor(0, type: :s32), {8})

      {_, state, _, ended, pcm, _, _, _, _} =
        while {frame = 0, state, cursor, ended, pcm, blocks, controls, master, count},
              frame < count do
          active = state[[.., 0]] != 0
          sample_index = state[[.., 5]]
          sample = gather_voice_sample(state[[.., 9..24]], sample_index)
          sample = Nx.select(active, sample, 0)
          volumes = controls[[.., 1..2]]
          channels = Nx.quotient(Nx.new_axis(sample, 1) * volumes, 128) |> Nx.sum(axes: [0])
          channels = Nx.quotient(channels * master[[1..2]], 128)
          channels = Nx.select(master[0] != 0, 0, Nx.clip(channels, -32_768, 32_767))
          pcm = Nx.put_slice(pcm, [frame, 0], Nx.new_axis(channels, 0))

          phase = state[[.., 6]] + controls[[.., 0]]
          steps = Nx.right_shift(phase, 12)
          state = Nx.put_slice(state, [0, 6], Nx.new_axis(band(phase, 0xFFF), 1))

          {state, cursor, ended} = advance_step({state, cursor, ended}, blocks, steps > 0)
          {state, cursor, ended} = advance_step({state, cursor, ended}, blocks, steps > 1)
          {state, cursor, ended} = advance_step({state, cursor, ended}, blocks, steps > 2)
          {state, cursor, ended} = advance_step({state, cursor, ended}, blocks, steps > 3)

          {frame + 1, state, cursor, ended, pcm, blocks, controls, master, count}
        end

      {state, pcm, ended}
    end

    defnp advance_step({state, cursor, ended}, blocks, step?) do
      active = state[[.., 0]] != 0
      block_end = state[[.., 3]] != 0
      block_loop = state[[.., 4]] != 0
      sample_index = state[[.., 5]]
      advance = active and step?
      crossing = advance and sample_index >= 15
      load = crossing and (not block_end or block_loop)
      stop = crossing and block_end and not block_loop
      next_block = gather_blocks(blocks, cursor)

      {decoded_samples, previous1, previous2} =
        decode_brr(next_block, state[[.., 7]], state[[.., 8]])

      header = next_block[[.., 1]]

      prefix =
        Nx.stack(
          [
            Nx.select(stop, 0, state[[.., 0]]),
            Nx.select(load, next_block[[.., 0]], state[[.., 1]]),
            state[[.., 2]],
            Nx.select(load, band(header, 1), state[[.., 3]]),
            Nx.select(load, band(Nx.right_shift(header, 1), 1), state[[.., 4]]),
            Nx.select(
              load,
              0,
              Nx.select(stop, 15, Nx.select(advance, sample_index + 1, sample_index))
            ),
            state[[.., 6]],
            Nx.select(load, previous1, state[[.., 7]]),
            Nx.select(load, previous2, state[[.., 8]])
          ],
          axis: 1
        )

      load_samples = Nx.broadcast(Nx.new_axis(load, 1), {8, 16})
      samples = Nx.select(load_samples, decoded_samples, state[[.., 9..24]])
      state = Nx.concatenate([prefix, samples], axis: 1)
      cursor = cursor + Nx.select(load, 1, 0)
      ended = Nx.select(crossing and block_end, 1, ended)
      {state, cursor, ended}
    end

    defnp decode_brr(block, initial1, initial2) do
      header = block[[.., 1]]
      range = Nx.right_shift(header, 4)
      filter = band(Nx.right_shift(header, 2), 3)
      bytes = block[[.., 2..9]]

      nibbles =
        Nx.stack([Nx.right_shift(bytes, 4), band(bytes, 0xF)], axis: 2)
        |> Nx.reshape({8, 16})

      samples = Nx.broadcast(Nx.tensor(0, type: :s32), {8, 16})

      {_, samples, previous1, previous2, _, _, _} =
        while {index = 0, samples, previous1 = initial1, previous2 = initial2, nibbles, range,
               filter},
              index < 16 do
          nibble = gather_voice_sample(nibbles, Nx.broadcast(index, {8}))
          nibble = Nx.select(nibble >= 8, nibble - 16, nibble)

          sample =
            Nx.select(
              range <= 12,
              Nx.right_shift(Nx.left_shift(nibble, range), 1),
              Nx.select(nibble < 0, -2048, 0)
            )

          filtered =
            Nx.select(
              filter == 0,
              sample,
              Nx.select(
                filter == 1,
                sample + previous1 + Nx.right_shift(-previous1, 4),
                Nx.select(
                  filter == 2,
                  sample + previous1 * 2 + Nx.right_shift(-3 * previous1, 5) - previous2 +
                    Nx.right_shift(previous2, 4),
                  sample + previous1 * 2 + Nx.right_shift(-13 * previous1, 6) - previous2 +
                    Nx.right_shift(3 * previous2, 4)
                )
              )
            )
            |> Nx.clip(-32_768, 32_767)

          samples = Nx.put_slice(samples, [0, index], Nx.new_axis(filtered, 1))
          {index + 1, samples, filtered, previous1, nibbles, range, filter}
        end

      {samples, previous1, previous2}
    end

    defnp gather_voice_sample(samples, indices) do
      flat = Nx.reshape(samples, {8 * 16})
      Nx.take(flat, Nx.iota({8}, type: :s32) * 16 + indices)
    end

    defnp gather_blocks(blocks, cursor) do
      flat = Nx.reshape(blocks, {8 * @block_capacity, 10})
      Nx.take(flat, Nx.iota({8}, type: :s32) * @block_capacity + cursor)
    end

    defnp(band(a, b), do: Nx.bitwise_and(a, b))

    defp render_chunk(voices, ram, mixer, count) do
      state = voices |> pack_state() |> Nx.tensor(type: :s32) |> resident()
      {voice_controls, muted?, master_left, master_right} = mixer

      blocks =
        voices |> pack_blocks(ram, voice_controls, count) |> Nx.tensor(type: :s32) |> resident()

      controls = voice_controls |> Tuple.to_list() |> Enum.map(&Tuple.to_list/1)
      controls = Nx.tensor(controls, type: :s32) |> resident()

      master =
        Nx.tensor([if(muted?, do: 1, else: 0), master_left, master_right], type: :s32)
        |> resident()

      count_tensor = Nx.tensor(count, type: :s32) |> resident()
      args = [state, blocks, controls, master, count_tensor]
      {state, pcm, ended} = apply(compiled(args), args)

      voices = unpack_state(Nx.to_flat_list(state))

      ended =
        ended
        |> Nx.to_flat_list()
        |> Enum.with_index()
        |> Enum.reduce(0, fn {flag, index}, mask ->
          if flag != 0, do: mask ||| 1 <<< index, else: mask
        end)

      pcm = pcm |> Nx.as_type(:s16) |> Nx.to_binary() |> binary_part(0, count * 4)
      {voices, ended, pcm}
    end

    defp render_mix_chunk(rows, volumes, master) do
      count = length(rows)
      padding = List.duplicate(List.duplicate(0, 8), @capacity - count)
      samples = rows |> Kernel.++(padding) |> Nx.tensor(type: :s32) |> resident()
      args = [samples, volumes, master]

      apply(compiled_mix(args), args)
      |> Nx.to_binary()
      |> binary_part(0, count * 4)
    end

    defp pack_state(voices) do
      voices
      |> Tuple.to_list()
      |> Enum.map(fn {active?, address, loop_address, block_end?, block_loop?, samples,
                      sample_index, phase, previous1, previous2} ->
        [
          bool(active?),
          address,
          loop_address,
          bool(block_end?),
          bool(block_loop?),
          sample_index,
          phase,
          previous1,
          previous2 | Tuple.to_list(samples)
        ]
      end)
    end

    defp unpack_state(values) do
      values
      |> Enum.chunk_every(@state_columns)
      |> Enum.map(fn [
                       active,
                       address,
                       loop_address,
                       block_end,
                       block_loop,
                       sample_index,
                       phase,
                       previous1,
                       previous2 | samples
                     ] ->
        {active != 0, address, loop_address, block_end != 0, block_loop != 0,
         List.to_tuple(samples), sample_index, phase, previous1, previous2}
      end)
      |> List.to_tuple()
    end

    defp pack_blocks(voices, ram, controls, count) do
      Enum.zip(Tuple.to_list(voices), Tuple.to_list(controls))
      |> Enum.map(fn {voice, {pitch, _left, _right}} ->
        loop_address = elem(voice, 2)
        needed = required_blocks(voice, pitch, count)

        blocks =
          collect_blocks(next_address(voice), loop_address, ram, needed, [])
          |> Enum.reverse()

        blocks ++ List.duplicate(List.duplicate(0, 10), @block_capacity - length(blocks))
      end)
    end

    defp required_blocks({false, _, _, _, _, _, _, _, _, _}, _pitch, _count), do: 0

    defp required_blocks({true, _, _, _, _, _, sample_index, phase, _, _}, pitch, count),
      do: min(div(sample_index + ((phase + pitch * count) >>> 12), 16), @block_capacity)

    defp collect_blocks(nil, _loop_address, _ram, _remaining, blocks), do: blocks
    defp collect_blocks(_address, _loop_address, _ram, 0, blocks), do: blocks

    defp collect_blocks(address, loop_address, ram, remaining, blocks) do
      bytes = for offset <- 0..8, do: :array.get(address + offset &&& 0xFFFF, ram)
      header = hd(bytes)

      next =
        cond do
          (header &&& 3) == 3 -> loop_address
          (header &&& 1) != 0 -> nil
          true -> address + 9 &&& 0xFFFF
        end

      collect_blocks(next, loop_address, ram, remaining - 1, [[address | bytes] | blocks])
    end

    defp next_address({false, _, _, _, _, _, _, _, _, _}), do: nil
    defp next_address({true, _, _, true, false, _, _, _, _, _}), do: nil
    defp next_address({true, _, loop_address, true, true, _, _, _, _, _}), do: loop_address
    defp next_address({true, address, _, false, _, _, _, _, _, _}), do: address + 9 &&& 0xFFFF

    defp chunk_sizes(frames) when frames <= @capacity, do: [frames]
    defp chunk_sizes(frames), do: [@capacity | chunk_sizes(frames - @capacity)]
    defp bool(true), do: 1
    defp bool(false), do: 0
    defp zero(shape), do: Nx.broadcast(Nx.tensor(0, type: :s32), shape) |> resident()
    defp resident(tensor), do: Nx.backend_copy(tensor, Beamicom.SNES.Nx.backend())

    defp compiled(args) do
      key = {@compiled_key, Beamicom.SNES.Nx.compiler_options()}

      case :persistent_term.get(key, nil) do
        nil ->
          compiled = Beamicom.SNES.Nx.compile(&synthesize/5, args)
          :persistent_term.put(key, compiled)
          compiled

        compiled ->
          compiled
      end
    end

    defp compiled_mix(args) do
      key = {@mix_key, Beamicom.SNES.Nx.compiler_options()}

      case :persistent_term.get(key, nil) do
        nil ->
          compiled = Beamicom.SNES.Nx.compile(&mix/3, args)
          :persistent_term.put(key, compiled)
          compiled

        compiled ->
          compiled
      end
    end
  end
end

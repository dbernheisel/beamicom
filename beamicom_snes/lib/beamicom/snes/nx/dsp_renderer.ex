if Code.ensure_loaded?(Nx.Defn) do
  defmodule Beamicom.SNES.Nx.DSPRenderer do
    @moduledoc "Compiled eight-voice SNES DSP synthesis and stereo mixing."

    import Bitwise, only: [&&&: 2, <<<: 2, >>>: 2, |||: 2]
    import Nx.Defn

    alias Beamicom.SNES.DSP.{Arithmetic, Echo, Gaussian}

    @capacity 544
    @block_capacity 140
    @state_columns 30
    @gaussian_coefficients Gaussian.coefficients()
    @counter_rates Beamicom.SNES.DSP.Envelope.counter_rates()
    @counter_offsets Beamicom.SNES.DSP.Envelope.counter_offsets()
    @pcm_compiled_key {__MODULE__, :synthesize_pcm_v9}
    @echo_compiled_key {__MODULE__, :synthesize_echo_v9}
    @mix_key {__MODULE__, :mix_v5}

    def minimum_frames, do: 64
    def synthesis_minimum_frames, do: 64

    def echo_synthesis_enabled?,
      do: Application.get_env(:beamicom_snes, :nx_echo_synthesis, false)

    def warmup do
      args = [
        zero({8, @state_columns}),
        zero({8, @block_capacity, 10}),
        zero({8}),
        zero({8, 6}),
        zero({3}),
        Nx.tensor(0, type: :s32) |> resident(),
        Nx.tensor(0, type: :s32) |> resident(),
        Nx.tensor(0, type: :s32) |> resident()
      ]

      compiled_pcm(args)
      compiled_echo(args)

      mix_args = [zero({@capacity, 8}), zero({8, 2}), zero({2})]
      compiled_mix(mix_args)
      :ok
    end

    @doc "Mixes frame-major eight-voice samples in one compiled tensor operation."
    def render(sample_rows, {voice_controls, muted?, master_left, master_right, _counter}) do
      volumes =
        voice_controls
        |> Tuple.to_list()
        |> Enum.map(fn {_pitch, left, right, _adsr1, _adsr2, _gain} -> [left, right] end)
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
      channels = Nx.broadcast(Nx.tensor(0, type: :s32), {@capacity, 2})

      {_, channels, _samples, _volumes} =
        while {voice = 0, channels, samples, volumes}, voice < 8 do
          sample = samples[[.., voice]] |> Nx.new_axis(1)
          contribution = Nx.quotient(sample * volumes[voice], 128)
          channels = Nx.clip(channels + contribution, -32_768, 32_767)
          {voice + 1, channels, samples, volumes}
        end

      channels = Nx.quotient(channels * master, 128)
      Nx.clip(channels, -32_768, 32_767) |> Nx.as_type(:s16)
    end

    @doc "Advances eight voices, decodes BRR blocks, and emits signed-16 stereo PCM."
    def render(voices, end_flags, ram, mixer, frames) do
      {_, _, _, _, counter} = mixer

      Enum.reduce(chunk_sizes(frames), {voices, end_flags, counter, []}, fn count,
                                                                            {voices, flags,
                                                                             counter, chunks} ->
        {voices, ended, counter, pcm, _buses} =
          render_chunk(voices, ram, mixer, counter, count, 0, :ignore)

        {voices, flags ||| ended, counter, [pcm | chunks]}
      end)
      |> then(fn {voices, flags, counter, chunks} ->
        {voices, flags, counter, chunks |> Enum.reverse() |> IO.iodata_to_binary()}
      end)
    end

    @doc "Synthesizes voice buses with Nx and advances authentic echo state and RAM."
    def render_echo(voices, end_flags, ram, mixer, frames, echo_state, registers) do
      eon = elem(registers, 0x4D)

      Enum.reduce(
        chunk_sizes(frames),
        {voices, end_flags, elem(mixer, 4), echo_state, ram, []},
        fn count, {voices, flags, counter, echo_state, ram, chunks} ->
          {voices, ended, counter, _voice_pcm, {main_rows, echo_rows}} =
            render_chunk(voices, ram, mixer, counter, count, eon, :echo)

          {echo_state, ram, pcm} =
            render_echo_rows(main_rows, echo_rows, echo_state, ram, registers)

          {voices, flags ||| ended, counter, echo_state, ram, [pcm | chunks]}
        end
      )
      |> then(fn {voices, flags, counter, echo_state, ram, chunks} ->
        {voices, flags, counter, chunks |> Enum.reverse() |> IO.iodata_to_binary(), echo_state,
         ram}
      end)
    end

    defn synthesize(state, blocks, block_counts, controls, master, eon, count, counter) do
      pcm = Nx.broadcast(Nx.tensor(0, type: :s32), {@capacity, 2})
      main_rows = Nx.broadcast(Nx.tensor(0, type: :s32), {@capacity, 2})
      echo_rows = Nx.broadcast(Nx.tensor(0, type: :s32), {@capacity, 2})
      cursor = Nx.broadcast(Nx.tensor(0, type: :s32), {8})
      ended = Nx.broadcast(Nx.tensor(0, type: :s32), {8})

      {decoded_blocks, decoded_previous1, decoded_previous2} =
        predecode_blocks(blocks, block_counts, state[[.., 7]], state[[.., 8]])

      {_, state, _, ended, pcm, main_rows, echo_rows, _, _, _, _, _, _, _, _, counter} =
        while {frame = 0, state, cursor, ended, pcm, main_rows, echo_rows, blocks, decoded_blocks,
               decoded_previous1, decoded_previous2, controls, master, eon, count, counter},
              frame < count do
          counter = Nx.select(counter == 0, 30_719, counter - 1)
          active = state[[.., 0]] != 0
          delay = state[[.., 29]]
          ready = active and delay == 0
          sample_index = state[[.., 5]]
          next_samples = gather_decoded_blocks(decoded_blocks, cursor)

          sample = gaussian_sample(state, next_samples, sample_index)
          sample = Nx.right_shift(sample * state[[.., 26]], 11) |> band(0xFFFE) |> signed16()
          sample = Nx.select(ready, sample, 0)
          volumes = controls[[.., 1..2]]
          channels = Nx.broadcast(Nx.tensor(0, type: :s32), {2})
          echo_channels = Nx.broadcast(Nx.tensor(0, type: :s32), {2})

          {_, channels, echo_channels, _sample, _volumes, _eon} =
            while {voice = 0, channels, echo_channels, sample, volumes, eon}, voice < 8 do
              contribution = Nx.quotient(sample[voice] * volumes[voice], 128)
              channels = Nx.clip(channels + contribution, -32_768, 32_767)

              echo_channels =
                Nx.select(
                  band(eon, Nx.left_shift(1, voice)) != 0,
                  Nx.clip(echo_channels + contribution, -32_768, 32_767),
                  echo_channels
                )

              {voice + 1, channels, echo_channels, sample, volumes, eon}
            end

          main_rows = Nx.put_slice(main_rows, [frame, 0], Nx.new_axis(channels, 0))
          echo_rows = Nx.put_slice(echo_rows, [frame, 0], Nx.new_axis(echo_channels, 0))
          channels = Nx.quotient(channels * master[[1..2]], 128)
          channels = Nx.select(master[0] != 0, 0, Nx.clip(channels, -32_768, 32_767))
          pcm = Nx.put_slice(pcm, [frame, 0], Nx.new_axis(channels, 0))

          phase = state[[.., 6]] + Nx.select(ready, controls[[.., 0]], 0)
          steps = Nx.right_shift(phase, 12)
          state = Nx.put_slice(state, [0, 6], Nx.new_axis(band(phase, 0xFFF), 1))

          decoded = {decoded_blocks, decoded_previous1, decoded_previous2}

          {state, cursor, ended} =
            advance_step({state, cursor, ended}, blocks, decoded, steps > 0)

          {state, cursor, ended} =
            advance_step({state, cursor, ended}, blocks, decoded, steps > 1)

          {state, cursor, ended} =
            advance_step({state, cursor, ended}, blocks, decoded, steps > 2)

          {state, cursor, ended} =
            advance_step({state, cursor, ended}, blocks, decoded, steps > 3)

          state = advance_envelopes(state, controls, counter, delay, active)

          {frame + 1, state, cursor, ended, pcm, main_rows, echo_rows, blocks, decoded_blocks,
           decoded_previous1, decoded_previous2, controls, master, eon, count, counter}
        end

      {state, pcm, main_rows, echo_rows, ended, counter}
    end

    defn synthesize_pcm(state, blocks, block_counts, controls, master, eon, count, counter) do
      {state, pcm, _main_rows, _echo_rows, ended, counter} =
        synthesize(state, blocks, block_counts, controls, master, eon, count, counter)

      {state, pcm, ended, counter}
    end

    defnp advance_step(
            {state, cursor, ended},
            blocks,
            {decoded_blocks, decoded_previous1, decoded_previous2},
            step?
          ) do
      active = state[[.., 0]] != 0
      block_end = state[[.., 3]] != 0
      block_loop = state[[.., 4]] != 0
      sample_index = state[[.., 5]]
      advance = active and step?
      crossing = advance and sample_index >= 15
      load = crossing and (not block_end or block_loop)
      stop = crossing and block_end and not block_loop
      next_block = gather_blocks(blocks, cursor)
      decoded_samples = gather_decoded_blocks(decoded_blocks, cursor)
      previous1 = gather_decoded_value(decoded_previous1, cursor)
      previous2 = gather_decoded_value(decoded_previous2, cursor)

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
      prior_sample = Nx.select(load, state[[.., 24]], state[[.., 25]])

      state =
        Nx.concatenate(
          [prefix, samples, Nx.new_axis(prior_sample, 1), state[[.., 26..29]]],
          axis: 1
        )

      cursor = cursor + Nx.select(load, 1, 0)
      ended = Nx.select(crossing and block_end, 1, ended)
      {state, cursor, ended}
    end

    defnp predecode_blocks(blocks, block_counts, initial1, initial2) do
      decoded_blocks = Nx.broadcast(Nx.tensor(0, type: :s32), {8, @block_capacity, 16})
      decoded_previous1 = Nx.broadcast(Nx.tensor(0, type: :s32), {8, @block_capacity})
      decoded_previous2 = Nx.broadcast(Nx.tensor(0, type: :s32), {8, @block_capacity})
      limit = Nx.reduce_max(block_counts)

      {_, decoded_blocks, decoded_previous1, decoded_previous2, _, _, _, _, _} =
        while {index = 0, decoded_blocks, decoded_previous1, decoded_previous2,
               previous1 = initial1, previous2 = initial2, blocks, block_counts, limit},
              index < limit do
          cursor = Nx.broadcast(index, {8})
          block = gather_blocks(blocks, cursor)
          {samples, next_previous1, next_previous2} = decode_brr(block, previous1, previous2)
          decode? = index < block_counts
          sample_mask = Nx.new_axis(decode?, 1) |> Nx.broadcast({8, 16})
          samples = Nx.select(sample_mask, samples, 0)
          stored_previous1 = Nx.select(decode?, next_previous1, 0)
          stored_previous2 = Nx.select(decode?, next_previous2, 0)

          decoded_blocks =
            Nx.put_slice(decoded_blocks, [0, index, 0], Nx.new_axis(samples, 1))

          decoded_previous1 =
            Nx.put_slice(decoded_previous1, [0, index], Nx.new_axis(stored_previous1, 1))

          decoded_previous2 =
            Nx.put_slice(decoded_previous2, [0, index], Nx.new_axis(stored_previous2, 1))

          previous1 = Nx.select(decode?, next_previous1, previous1)
          previous2 = Nx.select(decode?, next_previous2, previous2)

          {index + 1, decoded_blocks, decoded_previous1, decoded_previous2, previous1, previous2,
           blocks, block_counts, limit}
        end

      {decoded_blocks, decoded_previous1, decoded_previous2}
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
                sample + Nx.right_shift(previous1, 1) + Nx.right_shift(-previous1, 5),
                Nx.select(
                  filter == 2,
                  sample + previous1 + Nx.right_shift(-3 * previous1, 6) -
                    Nx.right_shift(previous2, 1) + Nx.right_shift(previous2, 5),
                  sample + previous1 + Nx.right_shift(-13 * previous1, 7) -
                    Nx.right_shift(previous2, 1) + Nx.right_shift(3 * previous2, 5)
                )
              )
            )
            |> Nx.clip(-32_768, 32_767)
            |> Nx.multiply(2)
            |> signed16()

          samples = Nx.put_slice(samples, [0, index], Nx.new_axis(filtered, 1))
          {index + 1, samples, filtered, previous1, nibbles, range, filter}
        end

      {samples, previous1, previous2}
    end

    defnp gaussian_sample(state, next_samples, sample_index) do
      samples = state[[.., 9..24]]
      prior_sample = state[[.., 25]]
      sample0 = gather_voice_sample(samples, Nx.max(sample_index - 1, 0))
      sample0 = Nx.select(sample_index == 0, prior_sample, sample0)
      sample1 = gather_voice_sample(samples, sample_index)
      sample2 = gather_voice_sample(samples, Nx.min(sample_index + 1, 15))
      sample2 = Nx.select(sample_index >= 15, gather_voice_sample(next_samples, 0), sample2)
      sample3 = gather_voice_sample(samples, Nx.min(sample_index + 2, 15))

      sample3 =
        Nx.select(
          sample_index >= 14,
          gather_voice_sample(next_samples, Nx.max(sample_index - 14, 0)),
          sample3
        )

      offset = Nx.right_shift(state[[.., 6]], 4)
      gaussian = Nx.tensor(@gaussian_coefficients, type: :s32)

      first_three =
        Nx.right_shift(Nx.take(gaussian, 255 - offset) * sample0, 11) +
          Nx.right_shift(Nx.take(gaussian, 511 - offset) * sample1, 11) +
          Nx.right_shift(Nx.take(gaussian, 256 + offset) * sample2, 11)

      last = Nx.right_shift(Nx.take(gaussian, offset) * sample3, 11)

      first_three
      |> signed16()
      |> Nx.add(last)
      |> Nx.clip(-32_768, 32_767)
      |> band(0xFFFE)
      |> signed16()
    end

    defnp advance_envelopes(state, controls, counter, old_delay, was_active) do
      envelope = state[[.., 26]]
      mode = state[[.., 27]]
      hidden = state[[.., 28]]
      delay = Nx.max(old_delay - 1, 0)
      adsr1 = controls[[.., 3]]
      adsr2 = controls[[.., 4]]
      gain = controls[[.., 5]]

      adsr? = band(adsr1, 0x80) != 0
      decay_or_sustain? = mode >= 2
      attack_rate = band(adsr1, 0x0F) * 2 + 1
      attack = envelope + Nx.select(attack_rate < 31, 0x20, 0x400)
      exponential = envelope - 1 - Nx.right_shift(envelope, 8)

      adsr_rate =
        Nx.select(mode == 2, band(Nx.right_shift(adsr1, 3), 0x0E) + 0x10, band(adsr2, 0x1F))

      adsr_envelope = Nx.select(decay_or_sustain?, exponential, attack)
      adsr_rate = Nx.select(decay_or_sustain?, adsr_rate, attack_rate)

      gain_mode = Nx.right_shift(gain, 5)
      gain_rate = band(gain, 0x1F)

      gain_envelope =
        Nx.select(
          gain_mode < 4,
          gain * 0x10,
          Nx.select(
            gain_mode == 4,
            envelope - 0x20,
            Nx.select(
              gain_mode == 5,
              exponential,
              Nx.select(
                gain_mode == 6,
                envelope + 0x20,
                envelope + Nx.select(hidden >= 0x600, 0x08, 0x20)
              )
            )
          )
        )

      rate = Nx.select(adsr?, adsr_rate, Nx.select(gain_mode < 4, 31, gain_rate))
      candidate = Nx.select(adsr?, adsr_envelope, gain_envelope)

      sustain_level? =
        adsr? and mode == 2 and
          Nx.right_shift(candidate, 8) == Nx.right_shift(adsr2, 5)

      next_mode = Nx.select(sustain_level?, 3, mode)
      attack_overflow? = next_mode == 1 and candidate > 0x7FF
      next_mode = Nx.select(attack_overflow?, 2, next_mode)
      candidate = Nx.clip(candidate, 0, 0x7FF)

      rates = Nx.tensor(@counter_rates, type: :s32)
      offsets = Nx.tensor(@counter_offsets, type: :s32)
      tick? = Nx.remainder(counter + Nx.take(offsets, rate), Nx.take(rates, rate)) == 0
      next_envelope = Nx.select(tick?, candidate, envelope)

      release? = mode == 0
      release_envelope = Nx.max(envelope - 8, 0)
      clock? = was_active and old_delay <= 1
      next_envelope = Nx.select(release?, release_envelope, next_envelope)
      next_hidden = Nx.select(release?, hidden, candidate)
      next_active = Nx.select(release? and release_envelope == 0, 0, state[[.., 0]])

      next_envelope = Nx.select(clock?, next_envelope, 0)
      next_hidden = Nx.select(clock?, next_hidden, 0)
      next_active = Nx.select(clock?, next_active, state[[.., 0]])
      next_envelope = Nx.select(was_active, next_envelope, envelope)
      next_hidden = Nx.select(was_active, next_hidden, hidden)
      next_mode = Nx.select(was_active, next_mode, mode)
      delay = Nx.select(was_active, delay, old_delay)

      Nx.put_slice(state, [0, 0], Nx.new_axis(next_active, 1))
      |> Nx.put_slice([0, 26], Nx.new_axis(next_envelope, 1))
      |> Nx.put_slice([0, 27], Nx.new_axis(next_mode, 1))
      |> Nx.put_slice([0, 28], Nx.new_axis(next_hidden, 1))
      |> Nx.put_slice([0, 29], Nx.new_axis(delay, 1))
    end

    defnp signed16(value) do
      value = band(value, 0xFFFF)
      Nx.select(value >= 0x8000, value - 0x10000, value)
    end

    defnp gather_voice_sample(samples, indices) do
      flat = Nx.reshape(samples, {8 * 16})
      Nx.take(flat, Nx.iota({8}, type: :s32) * 16 + indices)
    end

    defnp gather_blocks(blocks, cursor) do
      flat = Nx.reshape(blocks, {8 * @block_capacity, 10})
      Nx.take(flat, Nx.iota({8}, type: :s32) * @block_capacity + cursor)
    end

    defnp gather_decoded_blocks(blocks, cursor) do
      flat = Nx.reshape(blocks, {8 * @block_capacity, 16})
      Nx.take(flat, Nx.iota({8}, type: :s32) * @block_capacity + cursor)
    end

    defnp gather_decoded_value(values, cursor) do
      flat = Nx.reshape(values, {8 * @block_capacity})
      Nx.take(flat, Nx.iota({8}, type: :s32) * @block_capacity + cursor)
    end

    defnp(band(a, b), do: Nx.bitwise_and(a, b))

    defp render_chunk(voices, ram, mixer, counter, count, eon, bus_output) do
      state = voices |> pack_state() |> Nx.tensor(type: :s32) |> resident()
      {voice_controls, muted?, master_left, master_right, _counter} = mixer

      {blocks, block_counts} = pack_blocks(voices, ram, voice_controls, count)
      blocks = blocks |> Nx.tensor(type: :s32) |> resident()
      block_counts = block_counts |> Nx.tensor(type: :s32) |> resident()

      controls = voice_controls |> Tuple.to_list() |> Enum.map(&Tuple.to_list/1)
      controls = Nx.tensor(controls, type: :s32) |> resident()

      master =
        Nx.tensor([if(muted?, do: 1, else: 0), master_left, master_right], type: :s32)
        |> resident()

      count_tensor = Nx.tensor(count, type: :s32) |> resident()
      counter_tensor = Nx.tensor(counter, type: :s32) |> resident()
      eon_tensor = Nx.tensor(eon, type: :s32) |> resident()

      args = [
        state,
        blocks,
        block_counts,
        controls,
        master,
        eon_tensor,
        count_tensor,
        counter_tensor
      ]

      {state, pcm, ended, counter, buses} =
        case bus_output do
          :ignore ->
            {state, pcm, ended, counter} = apply(compiled_pcm(args), args)
            {state, pcm, ended, counter, nil}

          :echo ->
            {state, pcm, main_rows, echo_rows, ended, counter} =
              apply(compiled_echo(args), args)

            {state, pcm, ended, counter, {bus_rows(main_rows, count), bus_rows(echo_rows, count)}}
        end

      voices = unpack_state(Nx.to_flat_list(state))

      ended =
        ended
        |> Nx.to_flat_list()
        |> Enum.with_index()
        |> Enum.reduce(0, fn {flag, index}, mask ->
          if flag != 0, do: mask ||| 1 <<< index, else: mask
        end)

      pcm = pcm |> Nx.as_type(:s16) |> Nx.to_binary() |> binary_part(0, count * 4)

      {voices, ended, Nx.to_number(counter), pcm, buses}
    end

    defp bus_rows(rows, count) do
      rows
      |> Nx.slice([0, 0], [count, 2])
      |> Nx.to_flat_list()
      |> Enum.chunk_every(2)
      |> Enum.map(&List.to_tuple/1)
    end

    defp render_echo_rows(main_rows, echo_rows, echo_state, ram, registers) do
      muted? = (elem(registers, 0x6C) &&& 0x40) != 0

      Enum.zip(main_rows, echo_rows)
      |> Enum.reduce({echo_state, ram, []}, fn {main_bus, echo_bus}, {state, ram, pcm} ->
        ram_sample = echo_ram_sample(state, ram)

        {state, {left, right}, effects} =
          Echo.process_sample(state, registers, main_bus, echo_bus, ram_sample, muted?: muted?)

        ram = Enum.reduce(effects, ram, &Echo.apply_write_effect(&2, &1))
        sample = (left &&& 0xFFFF) ||| (right &&& 0xFFFF) <<< 16
        {state, ram, [sample | pcm]}
      end)
      |> then(fn {state, ram, pcm} ->
        pcm = pcm |> Enum.reverse() |> Enum.map(&sample_bytes/1) |> :erlang.list_to_binary()
        {state, ram, pcm}
      end)
    end

    defp sample_bytes(sample),
      do: [sample &&& 0xFF, sample >>> 8 &&& 0xFF, sample >>> 16 &&& 0xFF, sample >>> 24]

    defp echo_ram_sample(state, ram) do
      [left, right] = Echo.read_effects(state)

      {
        echo_ram_word(ram, left.address),
        echo_ram_word(ram, right.address)
      }
    end

    defp echo_ram_word(ram, address) do
      low = :array.get(address, ram)
      high = :array.get(address + 1 &&& 0xFFFF, ram)
      Arithmetic.signed16(low ||| high <<< 8)
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
                      sample_index, phase, previous1, previous2, prior_sample, envelope,
                      envelope_mode, hidden_envelope, kon_delay} ->
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
        ] ++ [prior_sample, envelope, envelope_mode, hidden_envelope, kon_delay]
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
                       previous2 | samples_and_prior
                     ] ->
        {samples, [prior_sample, envelope, envelope_mode, hidden_envelope, kon_delay]} =
          Enum.split(samples_and_prior, 16)

        {active != 0, address, loop_address, block_end != 0, block_loop != 0,
         List.to_tuple(samples), sample_index, phase, previous1, previous2, prior_sample,
         envelope, envelope_mode, hidden_envelope, kon_delay}
      end)
      |> List.to_tuple()
    end

    defp pack_blocks(voices, ram, controls, count) do
      {blocks, block_counts} =
        Enum.zip(Tuple.to_list(voices), Tuple.to_list(controls))
        |> Enum.map(fn {voice, {pitch, _left, _right, _adsr1, _adsr2, _gain}} ->
          loop_address = elem(voice, 2)
          needed = required_blocks(voice, pitch, count)

          blocks =
            collect_blocks(next_address(voice), loop_address, ram, needed, [])
            |> Enum.reverse()

          {blocks, length(blocks)}
        end)
        |> Enum.unzip()

      blocks =
        Enum.map(blocks, fn voice_blocks ->
          voice_blocks ++
            List.duplicate(List.duplicate(0, 10), @block_capacity - length(voice_blocks))
        end)

      {blocks, block_counts}
    end

    defp required_blocks(voice, _pitch, _count) when elem(voice, 0) == false, do: 0

    defp required_blocks(voice, pitch, count) do
      delay = elem(voice, 14)
      audible_count = max(count - delay, 0)
      sample_index = elem(voice, 6)
      phase = elem(voice, 7)

      min(
        div(sample_index + ((phase + pitch * audible_count) >>> 12) + 2, 16),
        @block_capacity
      )
    end

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

    defp next_address(voice) when elem(voice, 0) == false, do: nil
    defp next_address(voice) when elem(voice, 3) and not elem(voice, 4), do: nil
    defp next_address(voice) when elem(voice, 3) and elem(voice, 4), do: elem(voice, 2)
    defp next_address(voice), do: elem(voice, 1) + 9 &&& 0xFFFF

    defp chunk_sizes(frames) when frames <= @capacity, do: [frames]
    defp chunk_sizes(frames), do: [@capacity | chunk_sizes(frames - @capacity)]
    defp bool(true), do: 1
    defp bool(false), do: 0
    defp zero(shape), do: Nx.broadcast(Nx.tensor(0, type: :s32), shape) |> resident()
    defp resident(tensor), do: Nx.backend_copy(tensor, Beamicom.SNES.Nx.backend())

    defp compiled_pcm(args) do
      key = {@pcm_compiled_key, Beamicom.SNES.Nx.compiler_options()}

      case :persistent_term.get(key, nil) do
        nil ->
          compiled = Beamicom.SNES.Nx.compile(&synthesize_pcm/8, args)
          :persistent_term.put(key, compiled)
          compiled

        compiled ->
          compiled
      end
    end

    defp compiled_echo(args) do
      key = {@echo_compiled_key, Beamicom.SNES.Nx.compiler_options()}

      case :persistent_term.get(key, nil) do
        nil ->
          compiled = Beamicom.SNES.Nx.compile(&synthesize/8, args)
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

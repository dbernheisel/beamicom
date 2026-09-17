defmodule Beamicom.SNES.DSP do
  @moduledoc """
  Clock-accurate S-DSP voice, noise, mixer, and echo pipeline.

  `clock/2` is the correctness primitive. The block-oriented `render/3`
  and `render/4` APIs advance that same 32-phase pipeline, so partial clocks,
  APU register writes, and block rendering all share one authoritative state.
  DSP synthesis stays on the phase pipeline until an equivalent compiled state
  transition exists.
  """

  import Bitwise

  alias Beamicom.SNES.APU.RAM

  alias Beamicom.SNES.DSP.{
    Arithmetic,
    Clock,
    Echo,
    Mixer,
    Noise,
    Pipeline,
    VoicePipeline
  }

  @compile {:inline, pack_sample: 2, reg: 2, ram_get: 2}

  @empty_registers List.duplicate(0, 128) |> List.to_tuple()

  defstruct registers: @empty_registers, clock: %Clock{}

  @type t :: %__MODULE__{}

  def new, do: %__MODULE__{clock: Clock.new()}

  @doc "Returns the current S-DSP pipeline phase in the range 0 through 31."
  def phase(%__MODULE__{clock: clock}), do: clock.phase

  @doc "Returns the number of stereo samples committed by the clocked DSP."
  def sample_counter(%__MODULE__{clock: clock}), do: clock.sample_counter

  @doc "Returns one authoritative phase-pipeline voice."
  def voice(%__MODULE__{clock: clock}, index) when index in 0..7,
    do: VoicePipeline.voice(clock.voice_pipeline, index)

  @doc false
  def ram_dependency_addresses(%__MODULE__{} = dsp, ram, clocks)
      when is_integer(clocks) and clocks >= 0 do
    samples = div(dsp.clock.phase + clocks + 31, 32) + 1
    voice_pipeline = dsp.clock.voice_pipeline

    global_directory = voice_pipeline.brr.directory_address &&& 0xFFFF
    addresses = add_directory_addresses(MapSet.new(), global_directory)

    {addresses, brr_regions, maximum_blocks} =
      Enum.reduce(0..7, {addresses, [], 0}, fn index, {addresses, brr_regions, maximum_blocks} ->
        voice = VoicePipeline.voice(voice_pipeline, index)
        directories = dependency_directories(voice_pipeline, voice)

        if voice_dependency_active?(voice_pipeline, voice, index) do
          addresses = Enum.reduce(directories, addresses, &add_directory_addresses(&2, &1))
          pitch = dependency_pitch(voice_pipeline, voice, index)
          blocks = div((voice.gaussian_offset &&& 0x3FFF) + pitch * samples, 0x4000) + 2

          brr_regions =
            Enum.reduce(directories, brr_regions, fn directory, brr_regions ->
              start_address = ram_word(ram, directory)
              loop_address = ram_word(ram, directory + 2)

              [voice.brr_address, start_address]
              |> Enum.uniq()
              |> Enum.reduce(brr_regions, fn block_address, brr_regions ->
                collect_ram_dependency_regions(
                  block_address,
                  loop_address,
                  ram,
                  blocks,
                  brr_regions,
                  MapSet.new()
                )
              end)
            end)

          {addresses, brr_regions, max(maximum_blocks, blocks)}
        else
          {addresses, brr_regions, maximum_blocks}
        end
      end)

    brr_regions =
      if maximum_blocks == 0 do
        brr_regions
      else
        global_start = ram_word(ram, global_directory)
        global_loop = ram_word(ram, global_directory + 2)

        [voice_pipeline.brr.next_address, global_start, global_loop]
        |> Enum.uniq()
        |> Enum.reduce(brr_regions, fn block_address, brr_regions ->
          collect_ram_dependency_regions(
            block_address,
            global_loop,
            ram,
            maximum_blocks,
            brr_regions,
            MapSet.new()
          )
        end)
      end

    echo_regions =
      if echo_required?(dsp),
        do: echo_dependency_regions(dsp),
        else: pending_echo_write_regions(dsp)

    case {brr_regions, echo_regions} do
      {[], []} ->
        addresses

      {[], echo_regions} ->
        {:regions, addresses, echo_regions}

      {brr_regions, echo_regions} ->
        {:dependencies, addresses, Enum.uniq(brr_regions), echo_regions}
    end
  end

  @doc "Reads the register snapshot captured at the start of the current sample."
  def latched_register(%__MODULE__{clock: clock}, address),
    do: Clock.read_latch(clock, address)

  def write(%__MODULE__{} = dsp, address, value) do
    address = address &&& 0x7F
    value = value &&& 0xFF

    dsp =
      case address do
        0x7C ->
          %{dsp | registers: put_elem(dsp.registers, address, 0)}

        _other ->
          %{dsp | registers: put_elem(dsp.registers, address, value)}
      end

    put_in(
      dsp.clock.voice_pipeline,
      VoicePipeline.write(dsp.clock.voice_pipeline, address, value)
    )
  end

  def read(%__MODULE__{} = dsp, 0x7C),
    do: VoicePipeline.read(dsp.clock.voice_pipeline, 0x7C)

  def read(%__MODULE__{} = dsp, address)
      when address in 0..0x7F and (address &&& 0x0F) in [0x08, 0x09],
      do: VoicePipeline.read(dsp.clock.voice_pipeline, address)

  def read(%__MODULE__{} = dsp, address), do: elem(dsp.registers, address &&& 0x7F)

  @doc false
  def scalar_required?(%__MODULE__{} = dsp) do
    reg(dsp, 0x3D) != 0 or (reg(dsp, 0x2D) &&& 0xFE) != 0 or echo_required?(dsp)
  end

  @doc "Renders signed-16 little-endian stereo frames from current DSP state."
  def render(%__MODULE__{} = dsp, ram, frames), do: render(dsp, ram, frames, :native)

  @doc "Renders through the authoritative phase pipeline."
  def render(%__MODULE__{} = dsp, _ram, 0, _renderer), do: {dsp, <<>>}

  def render(%__MODULE__{} = dsp, ram, frames, renderer) when frames > 0,
    do: clock(dsp, ram, frames * 32, renderer)

  @doc "Advances exactly one S-DSP clock and returns any completed stereo frame."
  def clock(%__MODULE__{} = dsp, ram) do
    {dsp, _ram, pcm} = clock_ram(dsp, ram, 1, :native)
    {dsp, pcm}
  end

  @doc "Advances an exact number of S-DSP clocks using the phase pipeline."
  def clock(%__MODULE__{} = dsp, ram, clocks), do: clock(dsp, ram, clocks, :native)

  @doc "Advances clocks; the renderer argument is retained for API compatibility."
  def clock(%__MODULE__{} = dsp, ram, clocks, renderer) do
    {dsp, _ram, pcm} = clock_ram(dsp, ram, clocks, renderer)
    {dsp, pcm}
  end

  @doc "Advances clocks while returning shared RAM after phase-timed DSP writes."
  def clock_ram(%__MODULE__{} = dsp, ram, clocks), do: clock_ram(dsp, ram, clocks, :native)

  def clock_ram(%__MODULE__{} = dsp, ram, 0, _renderer), do: {dsp, ram, <<>>}

  def clock_ram(%__MODULE__{} = dsp, ram, clocks, renderer)
      when is_integer(clocks) and clocks > 0 do
    {dsp, ram, samples} = clock_ram_samples(dsp, ram, clocks, renderer, [])
    {dsp, ram, pcm_binary(samples)}
  end

  @doc false
  def clock_ram_samples(%__MODULE__{} = dsp, ram, 0, _renderer, samples),
    do: {dsp, ram, samples}

  def clock_ram_samples(%__MODULE__{} = dsp, ram, clocks, _renderer, samples)
      when is_integer(clocks) and clocks > 0 and is_list(samples) do
    {dsp, ram, samples, remaining} = finish_partial_sample(dsp, ram, clocks, samples)
    sample_count = div(remaining, 32)
    trailing_clocks = rem(remaining, 32)
    {dsp, ram, samples} = advance_samples(dsp, ram, sample_count, samples)
    {dsp, ram, samples, 0} = advance_clocks(dsp, ram, trailing_clocks, samples)
    {dsp, ram, samples}
  end

  defp finish_partial_sample(%__MODULE__{clock: %{phase: 0}} = dsp, ram, clocks, pcm),
    do: {dsp, ram, pcm, clocks}

  defp finish_partial_sample(%__MODULE__{} = dsp, ram, clocks, pcm) do
    elapsed = min(clocks, 32 - dsp.clock.phase)
    {dsp, ram, pcm, 0} = advance_clocks(dsp, ram, elapsed, pcm)
    {dsp, ram, pcm, clocks - elapsed}
  end

  defp advance_clocks(dsp, ram, 0, pcm), do: {dsp, ram, pcm, 0}

  defp advance_clocks(dsp, ram, clocks, pcm) do
    {dsp, ram, sample} = clock_once(dsp, ram)
    pcm = if is_nil(sample), do: pcm, else: [sample | pcm]
    {dsp, ram, pcm, remaining} = advance_clocks(dsp, ram, clocks - 1, pcm)
    {dsp, ram, pcm, remaining}
  end

  defp advance_samples(dsp, ram, 0, pcm), do: {dsp, ram, pcm}

  defp advance_samples(dsp, ram, samples, pcm) do
    {dsp, ram, sample} = advance_sample(dsp, ram)
    advance_samples(dsp, ram, samples - 1, [sample | pcm])
  end

  defp advance_sample(%__MODULE__{clock: %{phase: 0}} = dsp, ram) do
    clock = Clock.latch(dsp.clock, dsp.registers, nil)
    noise_sample = Noise.sample(clock.noise)
    voice0 = VoicePipeline.voice(clock.voice_pipeline, 0)
    voice0_live = {voice0.envx, voice0.output}

    {voice_pipeline, buses} =
      VoicePipeline.advance_bus_before_echo(
        clock.voice_pipeline,
        ram,
        clock.pipeline,
        noise_sample
      )

    {echo_left, echo?} =
      if echo_sample?(%{dsp | clock: clock}),
        do: {read_echo_channel(clock.echo_state, ram, :left), true},
        else: {nil, false}

    {echo_state, output, effects} =
      if echo? do
        echo_right = read_echo_channel(clock.echo_state, ram, :right)

        Echo.process_sample_transition(
          clock.echo_state,
          clock.registers,
          buses.main_bus,
          buses.echo_bus,
          {echo_left, echo_right},
          muted?: (Clock.read_latch(clock, 0x6C) &&& 0x40) != 0
        )
      else
        {clock.echo_state, nil, {{0, 0, false}, {0, 0, false}}}
      end

    {voice_pipeline, buses} =
      VoicePipeline.advance_bus_to_output(voice_pipeline, ram, buses, noise_sample)

    dsp = %{dsp | clock: %{clock | voice_pipeline: voice_pipeline, pipeline: buses}}
    output = output || finalize_pipeline_output(dsp)
    next_buses = Pipeline.begin_sample(buses)

    {voice_pipeline, next_buses} =
      VoicePipeline.clock_bus(voice_pipeline, ram, 28, next_buses, noise_sample)

    flg_28 = reg(dsp, 0x6C)

    {voice_pipeline, next_buses} =
      VoicePipeline.clock_bus(voice_pipeline, ram, 29, next_buses, noise_sample)

    ram = effects |> elem(0) |> then(&Echo.apply_write(ram, &1))
    flg_29 = if echo?, do: reg(dsp, 0x6C), else: clock.echo_flg_29

    {voice_pipeline, next_buses} =
      VoicePipeline.clock_bus(voice_pipeline, ram, 30, next_buses, noise_sample)

    ram = effects |> elem(1) |> then(&Echo.apply_write(ram, &1))
    noise = Noise.clock(clock.noise, reg(dsp, 0x6C), voice_pipeline.counter)

    {voice_pipeline, next_buses} =
      VoicePipeline.clock_bus(voice_pipeline, ram, 31, next_buses, noise_sample)

    {voice0_envx, voice0_output} = voice0_live

    voice_pipeline =
      VoicePipeline.publish_aligned_live(voice_pipeline, voice0_envx, voice0_output)

    clock = %{
      clock
      | voice_pipeline: voice_pipeline,
        pipeline: next_buses,
        noise: noise,
        echo_state: echo_state,
        echo_flg_28: flg_28,
        echo_flg_29: flg_29
    }

    clock = Clock.finish_aligned_sample(clock, next_buses)

    dsp = %{dsp | clock: clock}

    {left, right} = output
    {dsp, ram, pack_sample(left, right)}
  end

  defp clock_once(%__MODULE__{clock: %{phase: phase}} = dsp, ram) do
    dsp = advance_voice_pipeline_bus(dsp, ram, phase)
    clock_effects_once(dsp, ram)
  end

  defp clock_effects_once(%__MODULE__{clock: %{phase: 0}} = dsp, ram) do
    clock = Clock.latch(dsp.clock, dsp.registers, nil) |> Clock.advance()
    {%{dsp | clock: clock}, ram, nil}
  end

  defp clock_effects_once(%__MODULE__{clock: %{phase: 22}} = dsp, ram) do
    if echo_sample?(dsp) do
      left = read_echo_channel(dsp.clock.echo_state, ram, :left)
      clock = %{dsp.clock | echo_left_read: left} |> Clock.advance()
      {%{dsp | clock: clock}, ram, nil}
    else
      {%{dsp | clock: Clock.advance(dsp.clock)}, ram, nil}
    end
  end

  defp clock_effects_once(%__MODULE__{clock: %{phase: 23}} = dsp, ram) do
    if echo_sample?(dsp) do
      right = read_echo_channel(dsp.clock.echo_state, ram, :right)
      clock = %{dsp.clock | echo_right_read: right}
      {pcm, effects, next_echo} = complete_pipeline_echo(%{dsp | clock: clock})

      clock = %{
        clock
        | echo_pending_state: next_echo,
          echo_write_effects: effects,
          echo_pcm: pcm
      }

      {%{dsp | clock: Clock.advance(clock)}, ram, nil}
    else
      {%{dsp | clock: Clock.advance(dsp.clock)}, ram, nil}
    end
  end

  defp clock_effects_once(%__MODULE__{clock: %{phase: 27}} = dsp, ram) do
    {left, right} = dsp.clock.echo_pcm || finalize_pipeline_output(dsp)
    pipeline = Pipeline.begin_sample(dsp.clock.pipeline)
    clock = %{dsp.clock | pipeline: pipeline, echo_pcm: {left, right}} |> Clock.advance()
    {%{dsp | clock: clock}, ram, nil}
  end

  defp clock_effects_once(%__MODULE__{clock: %{phase: 28}} = dsp, ram) do
    clock = %{dsp.clock | echo_flg_28: reg(dsp, 0x6C)} |> Clock.advance()
    {%{dsp | clock: clock}, ram, nil}
  end

  defp clock_effects_once(
         %__MODULE__{clock: %{phase: 29, echo_pending_state: next_echo}} = dsp,
         ram
       )
       when not is_nil(next_echo) do
    ram = apply_echo_write(dsp.clock.echo_write_effects, ram, :left, dsp.clock.echo_flg_28)

    clock = %{
      dsp.clock
      | echo_state: next_echo,
        echo_flg_29: reg(dsp, 0x6C)
    }

    {%{dsp | clock: Clock.advance(clock)}, ram, nil}
  end

  defp clock_effects_once(%__MODULE__{clock: %{phase: 30}} = dsp, ram) do
    ram =
      if is_nil(dsp.clock.echo_pending_state),
        do: ram,
        else: apply_echo_write(dsp.clock.echo_write_effects, ram, :right, dsp.clock.echo_flg_29)

    voice_pipeline = dsp.clock.voice_pipeline
    noise = Noise.clock(dsp.clock.noise, reg(dsp, 0x6C), voice_pipeline.counter)
    clock = %{dsp.clock | noise: noise} |> Clock.advance()
    {%{dsp | clock: clock}, ram, nil}
  end

  defp clock_effects_once(%__MODULE__{clock: %{phase: phase}} = dsp, ram) when phase in 1..30 do
    {%{dsp | clock: Clock.advance(dsp.clock)}, ram, nil}
  end

  defp clock_effects_once(%__MODULE__{clock: %{phase: 31}} = dsp, ram) do
    {left, right} = dsp.clock.echo_pcm || {0, 0}
    clock = Clock.finish_sample(dsp.clock, dsp.clock.pipeline)
    {%{dsp | clock: clock}, ram, pack_sample(left, right)}
  end

  defp advance_voice_pipeline_bus(dsp, ram, phase) do
    {voice_pipeline, pipeline} =
      VoicePipeline.clock_bus(
        dsp.clock.voice_pipeline,
        ram,
        phase,
        dsp.clock.pipeline,
        Noise.sample(dsp.clock.noise)
      )

    %{dsp | clock: %{dsp.clock | voice_pipeline: voice_pipeline, pipeline: pipeline}}
  end

  defp complete_pipeline_echo(dsp) do
    clock = dsp.clock
    ram_sample = {clock.echo_left_read || 0, clock.echo_right_read || 0}

    {next_echo, pcm, effects} =
      Echo.process_sample(
        clock.echo_state,
        clock.registers,
        clock.pipeline.main_bus,
        clock.pipeline.echo_bus,
        ram_sample,
        muted?: (latched_reg(dsp, 0x6C) &&& 0x40) != 0
      )

    {pcm, effects, next_echo}
  end

  defp finalize_pipeline_output(dsp) do
    Mixer.finalize(
      dsp.clock.pipeline.main_bus,
      {
        Arithmetic.signed8(latched_reg(dsp, 0x0C)),
        Arithmetic.signed8(latched_reg(dsp, 0x1C))
      },
      (latched_reg(dsp, 0x6C) &&& 0x40) != 0
    )
  end

  defp echo_sample?(dsp) do
    Echo.scalar_required?(dsp.clock.registers) or dsp.clock.echo_state != %Echo.State{}
  end

  defp echo_required?(dsp) do
    Echo.scalar_required?(dsp.registers) or dsp.clock.echo_state != %Echo.State{}
  end

  defp read_echo_channel(state, ram, channel) do
    {left_address, right_address} = Echo.read_addresses(state)
    address = if channel == :left, do: left_address, else: right_address
    low = ram_get(ram, address)
    high = ram_get(ram, address + 1 &&& 0xFFFF)
    Arithmetic.signed16(low ||| high <<< 8)
  end

  defp apply_echo_write(effects, ram, channel, flg) do
    case Enum.find(effects, &(&1.channel == channel)) do
      nil ->
        ram

      effect ->
        Echo.apply_write_effect(ram, %{effect | enabled?: (flg &&& 0x20) == 0})
    end
  end

  defp latched_reg(%__MODULE__{clock: clock}, address), do: Clock.read_latch(clock, address)

  defp dependency_directories(voice_pipeline, voice) do
    [
      voice_pipeline.brr.bank <<< 8 ||| voice.source <<< 2,
      voice_pipeline.brr.latched_bank <<< 8 ||| voice.source <<< 2
    ]
    |> Enum.map(&(&1 &&& 0xFFFF))
    |> Enum.uniq()
  end

  defp voice_dependency_active?(voice_pipeline, voice, index) do
    key_mask = 1 <<< index

    voice.active? or voice.keyon_delay > 0 or
      (voice_pipeline.key.kon_latch &&& key_mask) != 0 or
      (voice_pipeline.key.key_on &&& key_mask) != 0
  end

  defp dependency_pitch(voice_pipeline, voice, index) do
    pmon = voice_pipeline.pmon ||| voice_pipeline.latched_pmon
    if index > 0 and (pmon &&& 1 <<< index) != 0, do: 0x7FFF, else: voice.pitch
  end

  defp add_directory_addresses(addresses, directory) do
    Enum.reduce(0..3, addresses, fn offset, addresses ->
      MapSet.put(addresses, directory + offset &&& 0xFFFF)
    end)
  end

  defp collect_ram_dependency_regions(nil, _loop, _ram, _remaining, regions, _seen),
    do: regions

  defp collect_ram_dependency_regions(_address, _loop, _ram, 0, regions, _seen),
    do: regions

  defp collect_ram_dependency_regions(address, loop, ram, remaining, regions, seen) do
    if MapSet.member?(seen, address) do
      regions
    else
      header = ram_get(ram, address)
      regions = add_dependency_region(regions, address, 9)

      next =
        cond do
          (header &&& 3) == 3 -> loop
          (header &&& 1) != 0 -> nil
          true -> address + 9 &&& 0xFFFF
        end

      collect_ram_dependency_regions(
        next,
        loop,
        ram,
        remaining - 1,
        regions,
        MapSet.put(seen, address)
      )
    end
  end

  defp add_dependency_region([{base, length} | regions], address, added_length)
       when (base + length &&& 0xFFFF) == address do
    [{base, length + added_length} | regions]
  end

  defp add_dependency_region(regions, address, length), do: [{address, length} | regions]

  defp echo_dependency_regions(dsp) do
    state = dsp.clock.echo_state

    [
      {state.page <<< 8, max(state.length, 4)},
      {reg(dsp, 0x6D) <<< 8, max((reg(dsp, 0x7D) &&& 0x0F) * 0x800, 4)}
    ]
    |> Enum.uniq()
  end

  defp pending_echo_write_regions(dsp) do
    dsp.clock.echo_write_effects
    |> Enum.map(&{&1.address, 2})
    |> Enum.uniq()
  end

  defp pcm_binary(samples) do
    samples
    |> Enum.reverse()
    |> Enum.map(&sample_bytes/1)
    |> :erlang.list_to_binary()
  end

  defp sample_bytes(sample),
    do: [sample &&& 0xFF, sample >>> 8 &&& 0xFF, sample >>> 16 &&& 0xFF, sample >>> 24]

  defp pack_sample(left, right),
    do: (left &&& 0xFFFF) ||| (right &&& 0xFFFF) <<< 16

  defp reg(dsp, address), do: elem(dsp.registers, address)

  defp ram_get(ram, address), do: RAM.get(ram, address)
  defp ram_word(ram, address), do: ram_get(ram, address) ||| ram_get(ram, address + 1) <<< 8
end

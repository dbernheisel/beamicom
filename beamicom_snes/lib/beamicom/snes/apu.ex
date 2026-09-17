defmodule Beamicom.SNES.APU do
  @moduledoc """
  Native S-SMP/S-DSP timing and CPU-port boundary.

  The uploaded sound program runs on the native SPC700 interpreter. DSP voice
  synthesis is layered behind the same clock and register boundary; until that
  stage is complete, drained samples are deterministic silence.

  SPC memory accesses and DSP register accesses share an explicit common clock,
  including accesses from an instruction that temporarily overdraws its cycle
  grant. Only the small remainder of that one instruction is retained, bounded
  by `timeline_event_limit/0`; authoritative DSP output still runs in larger
  spans between accesses rather than looping once per master clock.

  The shared 64 KiB RAM is mutable and owned by one machine execution path.
  Call `snapshot/1` before retaining or branching an APU value.
  """

  import Bitwise
  alias Beamicom.SNES.{DSP, DSPTask, SPC700}
  alias Beamicom.SNES.APU.{RAM, TimelineSync}

  @sample_rate 32_000
  @spc_rate 1_024_000
  @async_min_frames 32
  @timeline_event_limit 16
  @echo_dependency_registers [
    0x0D,
    0x2C,
    0x3C,
    0x4D,
    0x0F,
    0x1F,
    0x2F,
    0x3F,
    0x4F,
    0x5F,
    0x6F,
    0x7F
  ]

  @compile {:inline,
            dependency_fence_survives_dsp_write?: 4, dependency_fence_survives_ram_write?: 4}

  defstruct cpu_to_apu: {0, 0, 0, 0},
            apu_to_cpu: {0xAA, 0xBB, 0, 0},
            ipl_state: :ready,
            ipl_counter: nil,
            ipl_address: 0,
            driver_entry: 0,
            driver_start_clocks: 0,
            ipl_pending_port0: nil,
            ram: nil,
            spc: nil,
            sample_phase: 0,
            spc_phase: 0,
            dsp_cycle_phase: 0,
            pending_frames: 0,
            pending_pcm: [],
            pending_spc_cycles: 0,
            timeline_events: [],
            elapsed_master_clocks: 0,
            async_dsp?: false,
            apu_renderer: :native,
            dsp_task: nil

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    renderer =
      Keyword.get(
        opts,
        :apu_renderer,
        Application.get_env(:beamicom_snes, :apu_renderer, :native)
      )

    warmup_renderer(renderer)

    apu = %__MODULE__{
      ram: RAM.new(),
      async_dsp?: Keyword.get(opts, :async_dsp, false),
      apu_renderer: renderer
    }

    if Keyword.get(opts, :native_ipl, false) do
      spc = %{SPC700.new(apu.ram, 0xFFC0) | control: 0xB0}
      %{apu | spc: spc, ipl_state: :running}
    else
      apu
    end
  end

  @spec cpu_read(t(), 0..3) :: byte()
  def cpu_read(%__MODULE__{spc: %SPC700{output_ports: ports}}, port) when port in 0..3,
    do: elem(ports, port)

  def cpu_read(%__MODULE__{apu_to_cpu: ports}, port) when port in 0..3,
    do: elem(ports, port)

  @spec cpu_write(t(), 0..3, byte()) :: t()
  def cpu_write(%__MODULE__{} = apu, port, value) when port in 0..3 do
    value = Bitwise.band(value, 0xFF)
    cpu_to_apu = put_elem(apu.cpu_to_apu, port, value)
    spc = if apu.spc, do: SPC700.put_input_port(apu.spc, port, value), else: nil
    apu = %{apu | cpu_to_apu: cpu_to_apu, spc: spc}

    cond do
      spc ->
        apu

      port == 0 and apu.ipl_state in [:ready, :upload] ->
        %{apu | ipl_pending_port0: value}

      true ->
        handle_ipl_write(apu, port, value)
    end
  end

  @doc false
  def sync_cpu_read(%__MODULE__{} = apu, port) when port in 0..3 do
    apu = apply_pending_ipl_write(apu)
    value = cpu_read(apu, port)
    {value, start_driver_after_ipl_ack(apu)}
  end

  @doc "APU-side helpers reserved for the forthcoming SPC700 interpreter."
  @spec apu_read_cpu_port(t(), 0..3) :: byte()
  def apu_read_cpu_port(%__MODULE__{cpu_to_apu: ports}, port) when port in 0..3,
    do: elem(ports, port)

  @spec apu_write_cpu_port(t(), 0..3, byte()) :: t()
  def apu_write_cpu_port(%__MODULE__{} = apu, port, value) when port in 0..3,
    do: %{apu | apu_to_cpu: put_elem(apu.apu_to_cpu, port, Bitwise.band(value, 0xFF))}

  @spec advance(t(), non_neg_integer(), :ntsc | :pal) :: t()
  def advance(%__MODULE__{} = apu, clocks, region)
      when is_integer(clocks) and clocks >= 0 and region in [:ntsc, :pal] do
    apu = apu |> finish_dsp_task() |> advance_driver_start(clocks)
    {clock_numerator, clock_denominator} = master_clock_ratio(region)
    sample_phase = apu.sample_phase + clocks * @sample_rate * clock_denominator
    spc_phase = apu.spc_phase + clocks * @spc_rate * clock_denominator
    frames = div(sample_phase, clock_numerator)
    spc_cycles = div(spc_phase, clock_numerator)

    if apu.async_dsp? and match?(%SPC700{}, apu.spc) and frames >= @async_min_frames and
         not DSP.scalar_required?(apu.spc.dsp) do
      {spc, dsp_task, timeline_events} =
        start_dsp_task(
          apu.spc,
          spc_cycles,
          apu.dsp_cycle_phase,
          frames,
          apu.apu_renderer,
          apu.timeline_events
        )

      %{
        apu
        | sample_phase: rem(sample_phase, clock_numerator),
          spc_phase: rem(spc_phase, clock_numerator),
          pending_spc_cycles: apu.pending_spc_cycles + spc_cycles,
          elapsed_master_clocks: apu.elapsed_master_clocks + clocks,
          spc: spc,
          apu_to_cpu: spc.output_ports,
          ram: spc.ram,
          timeline_events: timeline_events,
          dsp_task: dsp_task
      }
    else
      {spc, dsp_cycle_phase, samples, timeline_events} =
        advance_audio(
          apu.spc,
          spc_cycles,
          apu.dsp_cycle_phase,
          frames,
          apu.apu_renderer,
          apu.timeline_events
        )

      apu_to_cpu = if spc, do: spc.output_ports, else: apu.apu_to_cpu
      ram = if spc, do: spc.ram, else: apu.ram
      pending_pcm = if samples == [], do: apu.pending_pcm, else: [samples | apu.pending_pcm]
      rendered_frames = length(samples)

      %{
        apu
        | sample_phase: rem(sample_phase, clock_numerator),
          spc_phase: rem(spc_phase, clock_numerator),
          dsp_cycle_phase: dsp_cycle_phase,
          pending_frames: apu.pending_frames + rendered_frames,
          pending_pcm: pending_pcm,
          pending_spc_cycles: apu.pending_spc_cycles + spc_cycles,
          elapsed_master_clocks: apu.elapsed_master_clocks + clocks,
          spc: spc,
          apu_to_cpu: apu_to_cpu,
          ram: ram,
          timeline_events: timeline_events
      }
    end
  end

  @doc "Consumes the number of nominal SPC700 cycles ready to execute."
  @spec take_spc_cycles(t()) :: {non_neg_integer(), t()}
  def take_spc_cycles(%__MODULE__{pending_spc_cycles: cycles} = apu),
    do: {cycles, %{apu | pending_spc_cycles: 0}}

  @doc "Drains completed `{frame_count, signed-16 little-endian stereo PCM, updated_apu}`."
  @spec take_pcm(t()) :: {non_neg_integer(), binary(), t()}
  def take_pcm(%__MODULE__{pending_frames: frames, pending_pcm: chunks} = apu) do
    pcm =
      chunks
      |> Enum.reverse()
      |> Enum.map(fn samples -> samples |> Enum.reverse() |> Enum.map(&sample_bytes/1) end)
      |> :erlang.list_to_binary()

    {frames, pcm, %{apu | pending_frames: 0, pending_pcm: []}}
  end

  @doc "Waits for an in-flight DSP batch, then drains all completed PCM."
  @spec drain_pcm(t()) :: {non_neg_integer(), binary(), t()}
  def drain_pcm(%__MODULE__{} = apu), do: apu |> finish_dsp_task() |> take_pcm()

  @doc "Builds a detached, output-drained snapshot without consuming an in-flight DSP task."
  def snapshot(%__MODULE__{} = apu) do
    apu = drained_snapshot(apu)
    ram = RAM.clone(apu.ram)
    spc = if apu.spc, do: %{apu.spc | ram: ram}, else: nil
    %{apu | ram: ram, spc: spc}
  end

  @doc false
  def serialized_snapshot(%__MODULE__{} = apu) do
    apu = drained_snapshot(apu)
    ram = RAM.to_binary(apu.ram)
    spc = if apu.spc, do: %{apu.spc | ram: ram}, else: nil
    %{apu | ram: ram, spc: spc}
  end

  @doc false
  def restore_serialized_snapshot(%__MODULE__{ram: ram, spc: spc} = apu)
      when is_binary(ram) and byte_size(ram) == 0x10000 do
    cond do
      is_nil(spc) ->
        {:ok, %{apu | ram: RAM.from_binary(ram)}}

      match?(%SPC700{ram: ^ram}, spc) ->
        memory = RAM.from_binary(ram)
        {:ok, %{apu | ram: memory, spc: %{spc | ram: memory}}}

      true ->
        {:error, :corrupt}
    end
  end

  def restore_serialized_snapshot(_apu), do: {:error, :corrupt}

  defp drained_snapshot(apu) do
    apu
    |> finish_dsp_task(&DSPTask.peek/1)
    |> Map.merge(%{pending_frames: 0, pending_pcm: [], pending_spc_cycles: 0})
  end

  @doc false
  def timeline_event_limit, do: @timeline_event_limit

  defp start_dsp_task(
         %SPC700{} = spc,
         spc_cycles,
         dsp_cycle_phase,
         _frames,
         renderer,
         carried_events
       ) do
    start_cycles = spc.cycles
    debt = max(-spc.cycle_credit, 0)
    start_dsp = spc.dsp
    start_ram = RAM.clone(spc.ram)
    spc = prepare_spc_timeline(spc, carried_events, start_cycles, debt, spc_cycles)

    {events, spc, _timeline_clock} =
      SPC700.run_with_access_events(
        spc,
        spc_cycles,
        start_cycles,
        &sync_spc_access_replay/6
      )

    {due_events, timeline_events} =
      split_access_events(carried_events ++ events, start_cycles, debt, spc_cycles)

    ensure_timeline_event_limit!(timeline_events)

    timeline_ram =
      if RAM.mutable?(spc.ram),
        do: spc.ram,
        else: replay_ram_events(start_ram, due_events)

    task =
      DSPTask.start(fn ->
        {dsp, ram, dsp_cycle_phase, pcm} =
          render_audio_events(
            start_dsp,
            start_ram,
            due_events,
            start_cycles,
            debt,
            spc_cycles,
            dsp_cycle_phase,
            renderer
          )

        {dsp, ram, dsp_cycle_phase, length(pcm), pcm}
      end)

    {%{spc | ram: timeline_ram, dsp: start_dsp}, task, timeline_events}
  end

  defp finish_dsp_task(apu), do: finish_dsp_task(apu, &DSPTask.await/1)

  defp finish_dsp_task(%__MODULE__{dsp_task: nil} = apu, _read_result), do: apu

  defp finish_dsp_task(%__MODULE__{dsp_task: task} = apu, read_result) do
    {dsp, ram, dsp_cycle_phase, frames, pcm} = read_result.(task)
    spc = if apu.spc, do: %{apu.spc | dsp: dsp, ram: ram}, else: nil
    pending_pcm = if pcm == [], do: apu.pending_pcm, else: [pcm | apu.pending_pcm]

    %{
      apu
      | spc: spc,
        ram: ram,
        dsp_cycle_phase: dsp_cycle_phase,
        pending_frames: apu.pending_frames + frames,
        pending_pcm: pending_pcm,
        dsp_task: nil
    }
  end

  defp advance_audio(nil, spc_cycles, dsp_cycle_phase, frames, _renderer, _carried_events) do
    pcm = List.duplicate(0, frames)
    {nil, rem(dsp_cycle_phase + spc_cycles, 32), pcm, []}
  end

  defp advance_audio(
         %SPC700{} = spc,
         spc_cycles,
         dsp_cycle_phase,
         frames,
         renderer,
         carried_events
       ) do
    if Application.get_env(:beamicom_snes, :single_pass_apu, true) do
      advance_audio_single_pass(spc, spc_cycles, renderer, carried_events)
    else
      advance_audio_replay(
        spc,
        spc_cycles,
        dsp_cycle_phase,
        frames,
        renderer,
        carried_events
      )
    end
  end

  defp advance_audio_single_pass(spc, spc_cycles, renderer, carried_events) do
    start_cycles = spc.cycles
    debt = max(-spc.cycle_credit, 0)

    {spc, pcm} =
      prepare_spc_timeline_with_pcm(spc, carried_events, start_cycles, debt, spc_cycles)

    end_clock = start_cycles + max(spc_cycles - debt, 0)

    sync = %TimelineSync{
      preview_clock: start_cycles,
      end_clock: end_clock,
      renderer: renderer,
      dependencies: DSP.ram_dependency_addresses(spc.dsp, spc.ram, end_clock - start_cycles),
      pcm: pcm
    }

    {events, spc, sync} =
      SPC700.run_with_access_events(
        spc,
        spc_cycles,
        sync,
        &sync_spc_access/6,
        capture_after: end_clock,
        sync_filter: :dsp_timeline
      )

    {_due_events, timeline_events} =
      split_access_events(carried_events ++ events, start_cycles, debt, spc_cycles)

    ensure_timeline_event_limit!(timeline_events)
    {spc, pcm} = finish_spc_sync(spc, sync)
    {spc, DSP.phase(spc.dsp), pcm, timeline_events}
  end

  defp advance_audio_replay(
         spc,
         spc_cycles,
         dsp_cycle_phase,
         _frames,
         renderer,
         carried_events
       ) do
    start_cycles = spc.cycles
    debt = max(-spc.cycle_credit, 0)
    start_dsp = spc.dsp
    start_ram = RAM.clone(spc.ram)
    spc = prepare_spc_timeline(spc, carried_events, start_cycles, debt, spc_cycles)

    {events, spc, _timeline_clock} =
      SPC700.run_with_access_events(
        spc,
        spc_cycles,
        start_cycles,
        &sync_spc_access_replay/6
      )

    {due_events, timeline_events} =
      split_access_events(carried_events ++ events, start_cycles, debt, spc_cycles)

    ensure_timeline_event_limit!(timeline_events)

    {dsp, timeline_ram, dsp_cycle_phase, pcm} =
      render_audio_events(
        start_dsp,
        start_ram,
        due_events,
        start_cycles,
        debt,
        spc_cycles,
        dsp_cycle_phase,
        renderer
      )

    {%{spc | ram: timeline_ram, dsp: dsp}, dsp_cycle_phase, pcm, timeline_events}
  end

  defp render_audio_events(
         start_dsp,
         ram,
         events,
         start_cycles,
         debt,
         spc_cycles,
         _dsp_cycle_phase,
         renderer
       ) do
    {dsp, ram, pcm} =
      render_audio_timeline(
        start_dsp,
        ram,
        events,
        start_cycles,
        debt,
        spc_cycles,
        renderer,
        0,
        []
      )

    {dsp, ram, DSP.phase(dsp), pcm}
  end

  defp render_audio_timeline(
         dsp,
         ram,
         [],
         _start_cycles,
         _debt,
         spc_cycles,
         renderer,
         position,
         pcm
       ) do
    DSP.clock_ram_samples(dsp, ram, spc_cycles - position, renderer, pcm)
  end

  defp render_audio_timeline(
         dsp,
         ram,
         events,
         start_cycles,
         debt,
         spc_cycles,
         renderer,
         position,
         pcm
       ) do
    {before_barrier, barrier_and_after} =
      Enum.split_while(events, fn {_clock, kind, _address, _value} -> kind != :dsp_write end)

    boundary_event = List.first(barrier_and_after)
    boundary_position = event_position(boundary_event, start_cycles, debt, position, spc_cycles)
    dependencies = DSP.ram_dependency_addresses(dsp, ram, boundary_position - position)

    if dependencies == :all do
      [event | remaining_events] = events
      event_position = timeline_position(event, start_cycles, debt, position)

      {dsp, ram, pcm} =
        DSP.clock_ram_samples(dsp, ram, event_position - position, renderer, pcm)

      {dsp, ram} = apply_access_event(dsp, ram, event)

      render_audio_timeline(
        dsp,
        ram,
        remaining_events,
        start_cycles,
        debt,
        spc_cycles,
        renderer,
        event_position,
        pcm
      )
    else
      render_coalesced_timeline(
        dsp,
        ram,
        before_barrier,
        barrier_and_after,
        dependencies,
        start_cycles,
        debt,
        spc_cycles,
        renderer,
        position,
        boundary_position,
        pcm
      )
    end
  end

  defp render_coalesced_timeline(
         dsp,
         ram,
         before_barrier,
         barrier_and_after,
         dependencies,
         start_cycles,
         debt,
         spc_cycles,
         renderer,
         position,
         boundary_position,
         pcm
       ) do
    case split_at_ram_dependency(before_barrier, dependencies) do
      {before, [event | following_events]} ->
        event_position = timeline_position(event, start_cycles, debt, position)

        {dsp, ram, pcm} =
          DSP.clock_ram_samples(dsp, ram, event_position - position, renderer, pcm)

        ram = apply_ram_events(ram, before)
        {dsp, ram} = apply_access_event(dsp, ram, event)

        render_audio_timeline(
          dsp,
          ram,
          following_events ++ barrier_and_after,
          start_cycles,
          debt,
          spc_cycles,
          renderer,
          event_position,
          pcm
        )

      {before, []} ->
        {dsp, ram, pcm} =
          DSP.clock_ram_samples(dsp, ram, boundary_position - position, renderer, pcm)

        ram = apply_ram_events(ram, before)

        {dsp, ram, remaining_events} =
          case barrier_and_after do
            [event | remaining_events] ->
              {dsp, ram} = apply_access_event(dsp, ram, event)
              {dsp, ram, remaining_events}

            [] ->
              {dsp, ram, []}
          end

        render_audio_timeline(
          dsp,
          ram,
          remaining_events,
          start_cycles,
          debt,
          spc_cycles,
          renderer,
          boundary_position,
          pcm
        )
    end
  end

  defp event_position(nil, _start, _debt, _previous, spc_cycles), do: spc_cycles

  defp event_position(event, start, debt, previous, _spc_cycles),
    do: timeline_position(event, start, debt, previous)

  defp split_at_ram_dependency(events, dependencies) do
    Enum.split_while(events, fn {_clock, :ram_write, address, _value} ->
      not ram_dependency?(dependencies, address)
    end)
  end

  defp ram_dependency?(dependencies, address) when is_struct(dependencies, MapSet),
    do: MapSet.member?(dependencies, address)

  defp ram_dependency?({:regions, dependencies, regions}, address) do
    MapSet.member?(dependencies, address) or
      Enum.any?(regions, fn {base, length} -> (address - base &&& 0xFFFF) < length end)
  end

  defp ram_dependency?({:dependencies, dependencies, write_regions, read_write_regions}, address) do
    MapSet.member?(dependencies, address) or
      Enum.any?(write_regions, fn {base, length} -> (address - base &&& 0xFFFF) < length end) or
      Enum.any?(read_write_regions, fn {base, length} ->
        (address - base &&& 0xFFFF) < length
      end)
  end

  defp apply_ram_events(ram, events) do
    Enum.reduce(events, ram, fn {_clock, :ram_write, address, value}, ram ->
      RAM.put(ram, address, value)
    end)
  end

  defp split_access_events(events, start_cycles, debt, spc_cycles) do
    Enum.split_while(events, fn {event_clock, _kind, _address, _value} ->
      event_clock - start_cycles + debt <= spc_cycles
    end)
  end

  defp timeline_position({event_clock, _kind, _address, _value}, start, debt, previous),
    do: max(event_clock - start + debt, previous)

  defp prepare_spc_timeline(spc, events, start_cycles, debt, spc_cycles) do
    catch_up_cycles = min(spc_cycles, debt)

    {due_events, _remaining_events} =
      split_access_events(events, start_cycles, debt, catch_up_cycles)

    {dsp, ram, _phase, _pcm} =
      render_audio_events(
        spc.dsp,
        spc.ram,
        due_events,
        start_cycles,
        debt,
        catch_up_cycles,
        DSP.phase(spc.dsp),
        :native
      )

    %{spc | dsp: dsp, ram: ram}
  end

  defp prepare_spc_timeline_with_pcm(spc, events, start_cycles, debt, spc_cycles) do
    catch_up_cycles = min(spc_cycles, debt)

    {due_events, _remaining_events} =
      split_access_events(events, start_cycles, debt, catch_up_cycles)

    {dsp, ram, _phase, pcm} =
      render_audio_events(
        spc.dsp,
        spc.ram,
        due_events,
        start_cycles,
        debt,
        catch_up_cycles,
        DSP.phase(spc.dsp),
        :native
      )

    {%{spc | dsp: dsp, ram: ram}, pcm}
  end

  defp sync_spc_access_replay(
         spc,
         access_clock,
         _operation,
         _address,
         _value,
         timeline_clock
       ) do
    clocks = access_clock - timeline_clock

    if clocks < 0 do
      raise "SPC timeline access clocks must be monotonic"
    end

    {dsp, ram, _pcm} = DSP.clock_ram_samples(spc.dsp, spc.ram, clocks, :native, [])
    {:sync, %{spc | dsp: dsp, ram: ram}, access_clock}
  end

  defp sync_spc_access(
         spc,
         access_clock,
         operation,
         address,
         value,
         %TimelineSync{} = sync
       ) do
    previous_dependencies = sync.dependencies

    {requires_sync?, sync} =
      spc_access_requires_sync?(spc, sync, access_clock, operation, address)

    if requires_sync? do
      {spc, sync} = advance_spc_sync(spc, access_clock, sync)

      sync =
        retain_spc_dependencies(spc, sync, previous_dependencies, operation, address, value)

      {:sync, spc, sync}
    else
      maybe_store_spc_sync(spc, sync, previous_dependencies)
    end
  end

  defp maybe_store_spc_sync(spc, sync, nil), do: {:sync, spc, sync}

  defp maybe_store_spc_sync(spc, _sync, _dependencies), do: {:skip, spc}

  defp refresh_spc_dependencies(spc, sync) do
    clocks = max(sync.end_clock - sync.preview_clock, 0)

    %{
      sync
      | dependencies: DSP.ram_dependency_addresses(spc.dsp, spc.ram, clocks)
    }
  end

  defp invalidate_spc_dependencies(sync), do: %{sync | dependencies: nil}

  defp retain_spc_dependencies(
         _spc,
         %TimelineSync{boundary: nil} = sync,
         dependencies,
         :read,
         _address,
         _value
       )
       when not is_nil(dependencies),
       do: %{sync | dependencies: dependencies}

  defp retain_spc_dependencies(
         spc,
         %TimelineSync{boundary: nil} = sync,
         dependencies,
         :write,
         0xF3,
         value
       )
       when not is_nil(dependencies) do
    if dependency_fence_survives_dsp_write?(spc.dsp, spc.dsp_addr, value, dependencies),
      do: %{sync | dependencies: dependencies},
      else: sync
  end

  defp retain_spc_dependencies(
         spc,
         %TimelineSync{boundary: nil} = sync,
         dependencies,
         :write,
         address,
         value
       )
       when not is_nil(dependencies) do
    if dependency_fence_survives_ram_write?(spc.ram, address, value, dependencies),
      do: %{sync | dependencies: dependencies},
      else: sync
  end

  defp retain_spc_dependencies(
         _spc,
         sync,
         _dependencies,
         _operation,
         _address,
         _value
       ),
       do: sync

  @doc false
  def dependency_fence_survives_dsp_write?(dsp, address, value, dependencies) do
    not dsp_write_expands_dependencies?(dsp, address, value, dependencies)
  end

  @doc false
  def dependency_fence_survives_ram_write?(ram, address, value, dependencies) do
    RAM.get(ram, address) == (value &&& 0xFF) or
      not dependency_routing_write?(dependencies, address)
  end

  defp dsp_write_expands_dependencies?(dsp, address, value, dependencies) do
    address = address &&& 0x7F
    value = value &&& 0xFF

    cond do
      address == 0x4C ->
        value != 0

      (address &&& 0x0F) in [0x02, 0x03] ->
        pitch_after_write(dsp, address, value) > voice_pitch(dsp, address >>> 4)

      (address &&& 0x0F) == 0x04 ->
        DSP.read(dsp, address) != value

      address == 0x2D ->
        (value &&& bnot(DSP.read(dsp, address)) &&& 0xFE) != 0

      address in [0x5D, 0x6D, 0x7D] ->
        DSP.read(dsp, address) != value

      address in @echo_dependency_registers ->
        not echo_dependencies?(dependencies) and value != 0

      true ->
        false
    end
  end

  defp pitch_after_write(dsp, address, value) do
    index = address >>> 4
    low_address = index <<< 4 ||| 0x02
    high_address = low_address + 1

    low = if address == low_address, do: value, else: DSP.read(dsp, low_address)
    high = if address == high_address, do: value, else: DSP.read(dsp, high_address)
    low ||| (high &&& 0x3F) <<< 8
  end

  defp voice_pitch(dsp, index), do: DSP.voice(dsp, index).pitch

  defp echo_dependencies?({:regions, _addresses, regions}), do: regions != []

  defp echo_dependencies?({:dependencies, _addresses, _brr_regions, regions}),
    do: regions != []

  defp echo_dependencies?(_dependencies), do: false

  defp dependency_routing_write?(dependencies, address) when is_struct(dependencies, MapSet),
    do: MapSet.member?(dependencies, address)

  defp dependency_routing_write?({:regions, addresses, _echo_regions}, address),
    do: MapSet.member?(addresses, address)

  defp dependency_routing_write?(
         {:dependencies, addresses, brr_regions, _echo_regions},
         address
       ) do
    MapSet.member?(addresses, address) or brr_header_write?(brr_regions, address)
  end

  defp dependency_routing_write?(:all, _address), do: true

  defp brr_header_write?(regions, address) do
    Enum.any?(regions, fn {base, length} ->
      offset = address - base &&& 0xFFFF
      offset < length and rem(offset, 9) == 0
    end)
  end

  defp advance_spc_sync(
         _spc,
         access_clock,
         %TimelineSync{preview_clock: preview_clock}
       )
       when access_clock < preview_clock,
       do: raise("SPC timeline access clocks must be monotonic")

  defp advance_spc_sync(
         spc,
         access_clock,
         %TimelineSync{boundary: nil, preview_clock: preview_clock, end_clock: end_clock} = sync
       )
       when access_clock > end_clock do
    {dsp, ram, pcm} =
      DSP.clock_ram_samples(
        spc.dsp,
        spc.ram,
        end_clock - preview_clock,
        sync.renderer,
        sync.pcm
      )

    boundary_ram = ram
    preview_ram = RAM.overlay(ram)

    {preview_dsp, preview_ram, _preview_pcm} =
      DSP.clock_ram_samples(dsp, preview_ram, access_clock - end_clock, sync.renderer, [])

    sync = %{
      sync
      | preview_clock: access_clock,
        boundary: {dsp, boundary_ram},
        dependencies: nil,
        pcm: pcm
    }

    {%{spc | dsp: preview_dsp, ram: preview_ram}, sync}
  end

  defp advance_spc_sync(
         spc,
         access_clock,
         %TimelineSync{boundary: boundary, preview_clock: preview_clock} = sync
       )
       when not is_nil(boundary) do
    {dsp, ram, _pcm} =
      DSP.clock_ram_samples(
        spc.dsp,
        spc.ram,
        access_clock - preview_clock,
        sync.renderer,
        []
      )

    {%{spc | dsp: dsp, ram: ram}, %{sync | preview_clock: access_clock, dependencies: nil}}
  end

  defp advance_spc_sync(
         spc,
         access_clock,
         %TimelineSync{preview_clock: preview_clock} = sync
       ) do
    {dsp, ram, pcm} =
      DSP.clock_ram_samples(
        spc.dsp,
        spc.ram,
        access_clock - preview_clock,
        sync.renderer,
        sync.pcm
      )

    sync = %{
      sync
      | preview_clock: access_clock,
        dependencies: nil,
        pcm: pcm
    }

    {%{spc | dsp: dsp, ram: ram}, sync}
  end

  defp spc_access_requires_sync?(_spc, sync, _clock, _operation, 0xF3),
    do: {true, invalidate_spc_dependencies(sync)}

  defp spc_access_requires_sync?(
         _spc,
         %TimelineSync{boundary: nil, end_clock: end_clock} = sync,
         access_clock,
         _operation,
         _address
       )
       when access_clock > end_clock,
       do: {true, sync}

  defp spc_access_requires_sync?(
         spc,
         %TimelineSync{dependencies: nil} = sync,
         access_clock,
         operation,
         address
       ) do
    sync = refresh_spc_dependencies(spc, sync)
    spc_access_requires_sync?(spc, sync, access_clock, operation, address)
  end

  defp spc_access_requires_sync?(
         _spc,
         %TimelineSync{dependencies: dependencies} = sync,
         _access_clock,
         :write,
         address
       ) do
    {dependencies == :all or ram_dependency?(dependencies, address), sync}
  end

  defp spc_access_requires_sync?(
         _spc,
         %TimelineSync{dependencies: {:regions, _addresses, regions}} = sync,
         _access_clock,
         :read,
         address
       ) do
    required? =
      Enum.any?(regions, fn {base, length} -> (address - base &&& 0xFFFF) < length end)

    {required?, sync}
  end

  defp spc_access_requires_sync?(
         _spc,
         %TimelineSync{dependencies: {:dependencies, _addresses, _write_regions, regions}} = sync,
         _access_clock,
         :read,
         address
       ) do
    required? =
      Enum.any?(regions, fn {base, length} -> (address - base &&& 0xFFFF) < length end)

    {required?, sync}
  end

  defp spc_access_requires_sync?(_spc, sync, _access_clock, :read, _address),
    do: {false, sync}

  defp finish_spc_sync(spc, %TimelineSync{boundary: {dsp, ram}, pcm: pcm}),
    do: {%{spc | dsp: dsp, ram: ram}, pcm}

  defp finish_spc_sync(
         spc,
         %TimelineSync{preview_clock: preview_clock, end_clock: end_clock} = sync
       ) do
    {dsp, ram, pcm} =
      DSP.clock_ram_samples(
        spc.dsp,
        spc.ram,
        end_clock - preview_clock,
        sync.renderer,
        sync.pcm
      )

    {%{spc | dsp: dsp, ram: ram}, pcm}
  end

  defp replay_ram_events(ram, events) do
    Enum.reduce(events, ram, fn
      {_clock, :ram_write, address, value}, ram -> RAM.put(ram, address, value)
      {_clock, :dsp_write, _address, _value}, ram -> ram
    end)
  end

  defp ensure_timeline_event_limit!(events) do
    if length(events) > @timeline_event_limit,
      do: raise("SPC access event queue exceeded #{@timeline_event_limit} entries")
  end

  defp apply_access_event(dsp, ram, {_clock, :ram_write, address, value}),
    do: {dsp, RAM.put(ram, address, value)}

  defp apply_access_event(dsp, ram, {_clock, :dsp_write, address, value}),
    do: {DSP.write(dsp, address, value), ram}

  defp sample_bytes(sample),
    do: [sample &&& 0xFF, sample >>> 8 &&& 0xFF, sample >>> 16 &&& 0xFF, sample >>> 24]

  # NTSC is exactly 945/44 MHz. PAL's supplied master clock is integral in Hz.
  defp master_clock_ratio(:ntsc), do: {945_000_000, 44}
  defp master_clock_ratio(:pal), do: {21_281_370, 1}

  defp warmup_renderer(:native), do: :ok

  defp warmup_renderer(renderer) when is_atom(renderer) do
    if Code.ensure_loaded?(renderer) and function_exported?(renderer, :warmup, 0),
      do: renderer.warmup(),
      else: :ok
  end

  defp handle_ipl_write(%{ipl_state: :ready} = apu, 0, 0xCC), do: begin_upload(apu)

  defp handle_ipl_write(
         %{ipl_state: :running, apu_to_cpu: {0xAA, 0xBB, _, _}} = apu,
         0,
         0xCC
       ),
       do: begin_upload(apu)

  defp handle_ipl_write(
         %{ipl_state: :running, apu_to_cpu: {0xAA, 0xBB, _, _}} = apu,
         port,
         _value
       )
       when port in 1..3,
       do: apu

  defp handle_ipl_write(%{ipl_state: :upload} = apu, 0, counter) do
    sequential? = is_nil(apu.ipl_counter) or counter == (apu.ipl_counter + 1 &&& 0xFF)

    cond do
      sequential? ->
        data = elem(apu.cpu_to_apu, 1)

        %{
          apu
          | ram: RAM.put(apu.ram, apu.ipl_address, data),
            apu_to_cpu: put_elem(apu.apu_to_cpu, 0, counter),
            ipl_counter: counter,
            ipl_address: apu.ipl_address + 1 &&& 0xFFFF
        }

      elem(apu.cpu_to_apu, 1) == 0 ->
        entry = elem(apu.cpu_to_apu, 2) ||| elem(apu.cpu_to_apu, 3) <<< 8

        %{
          apu
          | apu_to_cpu: put_elem(apu.apu_to_cpu, 0, counter),
            ipl_state: :starting,
            driver_entry: entry,
            driver_start_clocks: 0
        }

      true ->
        address = elem(apu.cpu_to_apu, 2) ||| elem(apu.cpu_to_apu, 3) <<< 8

        %{
          apu
          | apu_to_cpu: put_elem(apu.apu_to_cpu, 0, counter),
            ipl_counter: nil,
            ipl_address: address
        }
    end
  end

  defp handle_ipl_write(%{ipl_state: :running} = apu, port, value) do
    if apu.spc do
      apu
    else
      apu = %{apu | apu_to_cpu: put_elem(apu.apu_to_cpu, port, value)}

      if apu.cpu_to_apu == {0, 0, 0, 0},
        do: %{apu | ipl_state: :restarting, driver_start_clocks: 2_048},
        else: apu
    end
  end

  defp handle_ipl_write(apu, _port, _value), do: apu

  defp apply_pending_ipl_write(%{ipl_pending_port0: nil} = apu), do: apu

  defp apply_pending_ipl_write(%{ipl_pending_port0: value} = apu) do
    apu = %{apu | ipl_pending_port0: nil}
    handle_ipl_write(apu, 0, value)
  end

  defp begin_upload(apu) do
    address = elem(apu.cpu_to_apu, 2) ||| elem(apu.cpu_to_apu, 3) <<< 8

    %{
      apu
      | apu_to_cpu: put_elem(apu.apu_to_cpu, 0, 0xCC),
        ipl_state: :upload,
        ipl_counter: nil,
        ipl_address: address,
        spc: nil
    }
  end

  defp start_driver_after_ipl_ack(%{ipl_state: :starting} = apu) do
    %{
      apu
      | apu_to_cpu: {0, 0, 0, 0},
        ipl_state: :running,
        driver_start_clocks: 0,
        pending_spc_cycles: 0,
        spc: SPC700.new(apu.ram, apu.driver_entry, apu.cpu_to_apu)
    }
  end

  defp start_driver_after_ipl_ack(apu), do: apu

  defp advance_driver_start(
         %{ipl_state: :restarting, driver_start_clocks: remaining} = apu,
         clocks
       )
       when clocks >= remaining do
    %{
      apu
      | apu_to_cpu: apu.apu_to_cpu |> put_elem(0, 0xAA) |> put_elem(1, 0xBB),
        ipl_state: :ready,
        driver_start_clocks: 0
    }
  end

  defp advance_driver_start(%{ipl_state: state} = apu, clocks)
       when state == :restarting,
       do: %{apu | driver_start_clocks: apu.driver_start_clocks - clocks}

  defp advance_driver_start(apu, _clocks), do: apu
end

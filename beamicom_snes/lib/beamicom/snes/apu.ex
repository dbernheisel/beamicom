defmodule Beamicom.SNES.APU do
  @moduledoc """
  Native S-SMP/S-DSP timing and CPU-port boundary.

  The uploaded sound program runs on the native SPC700 interpreter. DSP voice
  synthesis is layered behind the same clock and register boundary; until that
  stage is complete, drained samples are deterministic silence.

  Sample production is synchronized at the DSP's 32-SPC-cycle boundary so
  short-lived key and mixer changes retain their correct order. It never loops
  once per master clock.
  """

  import Bitwise
  alias Beamicom.SNES.{DSP, SPC700}

  @sample_rate 32_000
  @spc_rate 1_024_000

  defstruct cpu_to_apu: {0, 0, 0, 0},
            apu_to_cpu: {0xAA, 0xBB, 0, 0},
            ipl_state: :ready,
            ipl_counter: nil,
            ipl_address: 0,
            driver_entry: 0,
            driver_start_clocks: 0,
            ipl_pending_port0: nil,
            ram: :array.new(0x10000, default: 0, fixed: true),
            spc: nil,
            sample_phase: 0,
            spc_phase: 0,
            dsp_cycle_phase: 0,
            pending_frames: 0,
            pending_pcm: [],
            pending_spc_cycles: 0,
            elapsed_master_clocks: 0

  @type t :: %__MODULE__{}

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    apu = %__MODULE__{}

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

    if port == 0 and is_nil(spc) and apu.ipl_state in [:ready, :upload] do
      %{apu | ipl_pending_port0: value}
    else
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
    apu = advance_driver_start(apu, clocks)
    {clock_numerator, clock_denominator} = master_clock_ratio(region)
    sample_phase = apu.sample_phase + clocks * @sample_rate * clock_denominator
    spc_phase = apu.spc_phase + clocks * @spc_rate * clock_denominator
    frames = div(sample_phase, clock_numerator)
    spc_cycles = div(spc_phase, clock_numerator)

    {spc, dsp_cycle_phase, pcm} =
      advance_audio(apu.spc, spc_cycles, apu.dsp_cycle_phase, frames)

    apu_to_cpu = if spc, do: spc.output_ports, else: apu.apu_to_cpu
    ram = if spc, do: spc.ram, else: apu.ram
    pending_pcm = if pcm == <<>>, do: apu.pending_pcm, else: [pcm | apu.pending_pcm]

    %{
      apu
      | sample_phase: rem(sample_phase, clock_numerator),
        spc_phase: rem(spc_phase, clock_numerator),
        dsp_cycle_phase: dsp_cycle_phase,
        pending_frames: apu.pending_frames + frames,
        pending_pcm: pending_pcm,
        pending_spc_cycles: apu.pending_spc_cycles + spc_cycles,
        elapsed_master_clocks: apu.elapsed_master_clocks + clocks,
        spc: spc,
        apu_to_cpu: apu_to_cpu,
        ram: ram
    }
  end

  @doc "Consumes the number of nominal SPC700 cycles ready to execute."
  @spec take_spc_cycles(t()) :: {non_neg_integer(), t()}
  def take_spc_cycles(%__MODULE__{pending_spc_cycles: cycles} = apu),
    do: {cycles, %{apu | pending_spc_cycles: 0}}

  @doc "Drains `{frame_count, signed-16 little-endian stereo PCM, updated_apu}`."
  @spec take_pcm(t()) :: {non_neg_integer(), binary(), t()}
  def take_pcm(%__MODULE__{pending_frames: frames, pending_pcm: chunks} = apu) do
    pcm = chunks |> Enum.reverse() |> IO.iodata_to_binary()
    {frames, pcm, %{apu | pending_frames: 0, pending_pcm: []}}
  end

  defp advance_audio(nil, spc_cycles, dsp_cycle_phase, frames) do
    pcm = :binary.copy(<<0::signed-little-16, 0::signed-little-16>>, frames)
    {nil, rem(dsp_cycle_phase + spc_cycles, 32), pcm}
  end

  defp advance_audio(%SPC700{} = spc, spc_cycles, dsp_cycle_phase, _frames) do
    start_cycles = spc.cycles
    debt = max(-spc.cycle_credit, 0)
    start_dsp = spc.dsp
    {events, spc} = SPC700.run_with_dsp_events(spc, spc_cycles)

    {dsp, dsp_cycle_phase, pcm, position} =
      Enum.reduce(events, {start_dsp, dsp_cycle_phase, [], 0}, fn
        {event_cycle, address, value}, {dsp, phase, pcm, position} ->
          event_position = (event_cycle - start_cycles + debt) |> max(position) |> min(spc_cycles)
          {dsp, phase, chunk} = render_dsp_span(dsp, spc.ram, event_position - position, phase)
          pcm = if chunk == <<>>, do: pcm, else: [chunk | pcm]
          {DSP.write(dsp, address, value), phase, pcm, event_position}
      end)

    {dsp, dsp_cycle_phase, tail} =
      render_dsp_span(dsp, spc.ram, spc_cycles - position, dsp_cycle_phase)

    pcm = if tail == <<>>, do: pcm, else: [tail | pcm]
    {%{spc | dsp: dsp}, dsp_cycle_phase, pcm |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp render_dsp_span(dsp, ram, cycles, phase) do
    elapsed = phase + cycles
    frames = div(elapsed, 32)
    {dsp, pcm} = DSP.render(dsp, ram, frames)
    {dsp, rem(elapsed, 32), pcm}
  end

  # NTSC is exactly 945/44 MHz. PAL's supplied master clock is integral in Hz.
  defp master_clock_ratio(:ntsc), do: {945_000_000, 44}
  defp master_clock_ratio(:pal), do: {21_281_370, 1}

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
          | ram: :array.set(apu.ipl_address, data, apu.ram),
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

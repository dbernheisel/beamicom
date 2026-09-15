defmodule Beamicom.Scenic.SNESSystem do
  @moduledoc """
  Temporary host adapter for inspecting the in-progress SNES core in Scenic.

  CPU execution errors freeze the machine at the point of failure and keep
  presenting its last PPU state. This deliberately favors bring-up and visual
  inspection over treating the unfinished core as production-ready.
  """

  @behaviour Beamicom.Host.System

  alias Beamicom.Host.{AudioChunk, Input, InputCapabilities, VideoFrame}
  alias Beamicom.SNES.{Machine, PPU}

  @buttons ~w(up down left right a b x y l r start select)a
  @frame_rate 60.0988
  @period_ns round(1_000_000_000 / @frame_rate)
  @width 256
  @height 224
  @audio_rate 32_000
  @compile {:no_warn_undefined, Beamicom.SNES.Nx.DSPRenderer}
  @button_bits %{
    b: 0x8000,
    y: 0x4000,
    select: 0x2000,
    start: 0x1000,
    up: 0x0800,
    down: 0x0400,
    left: 0x0200,
    right: 0x0100,
    a: 0x0080,
    x: 0x0040,
    l: 0x0020,
    r: 0x0010
  }

  defmodule State do
    @moduledoc false
    @enforce_keys [:machine]
    defstruct [:machine, :halted, frame_number: 0]
  end

  @impl true
  def id, do: :snes

  @impl true
  def capabilities do
    %{
      media_extensions: [".sfc", ".smc"],
      input: InputCapabilities.new(%{1 => @buttons}),
      video: %{width: @width, height: @height, pixel_formats: [:rgb24], frame_rate: @frame_rate},
      audio: %{sample_rate: @audio_rate, channels: 2, sample_format: :s16le}
    }
  end

  @impl true
  def load(media, options \\ []) do
    options =
      options
      |> Keyword.put_new(:render_pipeline, true)
      |> Keyword.put_new(:async_dsp, true)
      |> Keyword.put_new(:apu_renderer, default_apu_renderer())

    with {:ok, machine} <- Machine.load(media, options) do
      {:ok, %State{machine: machine}}
    end
  end

  @impl true
  def run_slice(%State{halted: nil} = state) do
    case Machine.run_until_frame(state.machine) do
      {:ok, machine, frame} ->
        {sample_count, pcm, machine} = Machine.take_audio_pcm(machine)
        state = %{state | machine: machine, frame_number: frame.number + 1}
        {state, [video_frame(frame), audio_chunk(sample_count, pcm)]}

      {:error, reason, machine} ->
        frame = PPU.render_frame(machine.bus.ppu)
        state = %{state | machine: machine, halted: reason, frame_number: frame.number + 1}
        {state, [video_frame(frame, halted: reason)]}
    end
  end

  def run_slice(%State{} = state) do
    frame = PPU.render_frame(state.machine.bus.ppu) |> Map.put(:number, state.frame_number)
    state = %{state | frame_number: state.frame_number + 1}
    {state, [video_frame(frame, halted: state.halted)]}
  end

  @impl true
  def set_input(%State{} = state, %Input{port: 1, controls: controls}) do
    report = Enum.reduce(controls, 0, &Bitwise.bor(&2, Map.get(@button_bits, &1, 0)))
    %{state | machine: Machine.set_joypad(state.machine, 1, report)}
  end

  def set_input(%State{} = state, %Input{}), do: state

  defp video_frame(frame, metadata \\ []) do
    %VideoFrame{
      system: :snes,
      number: frame.number,
      width: @width,
      height: @height,
      pixel_format: :rgb24,
      data: normalize_frame(frame),
      duration_ns: @period_ns,
      metadata: Map.new(metadata)
    }
  end

  defp audio_chunk(sample_count, pcm) do
    %AudioChunk{
      system: :snes,
      sample_rate: @audio_rate,
      channels: 2,
      sample_format: :s16le,
      frame_count: sample_count,
      data: pcm
    }
  end

  defp default_apu_renderer do
    if Code.ensure_loaded?(Beamicom.SNES.Nx.DSPRenderer),
      do: Beamicom.SNES.Nx.DSPRenderer,
      else: :native
  end

  defp normalize_frame(%{width: @width, height: height, data: data}) when height >= @height,
    do: binary_part(data, 0, @width * @height * 3)
end

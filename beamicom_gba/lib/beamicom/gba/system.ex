defmodule Beamicom.GBA.System do
  @moduledoc "Game Boy Advance implementation of the coarse Beamicom host contract."

  @behaviour Beamicom.Host.System

  alias Beamicom.GBA.Machine
  alias Beamicom.Host.{AudioChunk, Input, InputCapabilities, VideoFrame}

  @buttons ~w(up down left right a b l r start select)a
  @frame_cycles 280_896
  @clock_rate 16_777_216
  @period_ns round(@frame_cycles * 1_000_000_000 / @clock_rate)

  @impl true
  def id, do: :gba

  @impl true
  def capabilities do
    %{
      media_extensions: [".gba"],
      input: InputCapabilities.new(%{1 => @buttons}),
      video: %{
        width: 240,
        height: 160,
        pixel_formats: [:rgb24],
        frame_rate: @clock_rate / @frame_cycles
      },
      audio: %{sample_rate: 44_100, channels: 2, sample_format: :s16le},
      maturity: :diagnostic
    }
  end

  @impl true
  def load(media, opts \\ []), do: Machine.load(media, opts)

  @impl true
  def run_slice(%Machine{} = machine) do
    case Machine.run_until_frame(machine) do
      {:ok, machine, number, frame, sample_count, pcm} ->
        video = %VideoFrame{
          system: :gba,
          number: number,
          width: 240,
          height: 160,
          pixel_format: :rgb24,
          data: frame,
          duration_ns: @period_ns,
          metadata: %{maturity: :diagnostic}
        }

        audio = %AudioChunk{
          system: :gba,
          sample_rate: 44_100,
          channels: 2,
          sample_format: :s16le,
          frame_count: sample_count,
          data: pcm
        }

        {machine, [video, audio]}

      {:error, :frame_timeout, _machine} ->
        raise "Game Boy Advance did not produce a frame"

      {:error, reason, _machine} ->
        raise "Game Boy Advance execution stopped: #{inspect(reason)}"
    end
  end

  @impl true
  def set_input(%Machine{} = machine, %Input{port: 1, controls: controls}),
    do: Machine.set_buttons(machine, MapSet.to_list(controls))

  def set_input(%Machine{} = machine, %Input{}), do: machine
end

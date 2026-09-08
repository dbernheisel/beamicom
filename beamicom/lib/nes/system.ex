defmodule Beamicom.NES.System do
  @moduledoc "NES implementation of the coarse-grained `Beamicom.Host.System` contract."

  @behaviour Beamicom.Host.System

  alias Beamicom.Host.{AudioChunk, Input, InputCapabilities}
  alias Beamicom.NES.{Bus, CPU, Console, Output}

  @buttons ~w(up down left right a b start select)a
  @max_instructions_per_frame 1_000_000

  @impl true
  def id, do: :nes

  @impl true
  def capabilities do
    %{
      media_extensions: [".nes"],
      input: InputCapabilities.new(%{1 => @buttons, 2 => @buttons}),
      video: %{
        width: 256,
        height: 240,
        pixel_formats: [{:native, :nes_framebuffer}],
        frame_rate: 60.0988
      },
      audio: %{sample_rate: 44_100, channels: 1, sample_format: :s16le}
    }
  end

  @impl true
  def load(media, _opts \\ []) when is_binary(media) do
    case Beamicom.NES.Cart.parse(media) do
      {:ok, _cart} -> {:ok, Console.load_binary(media)}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def run_slice(%Console{} = console) do
    after_number =
      case console.bus.ppu.frame_ready do
        nil -> -1
        frame -> frame.number
      end

    {console, frame} = next_frame(console, after_number, @max_instructions_per_frame)
    {sample_count, pcm, bus} = Bus.take_audio_pcm(console.bus)
    console = %{console | bus: bus}

    audio = %AudioChunk{
      system: :nes,
      sample_rate: 44_100,
      channels: 1,
      sample_format: :s16le,
      frame_count: sample_count,
      data: pcm
    }

    {console, [Output.video_frame(frame), audio]}
  end

  @impl true
  def set_input(%Console{} = console, %Input{port: port, controls: controls})
      when port in [1, 2] do
    Console.set_buttons(console, port, MapSet.to_list(controls))
  end

  defp next_frame(_console, _after_number, 0), do: raise("NES did not produce a frame")

  defp next_frame(%Console{cpu: cpu, bus: bus} = console, after_number, remaining) do
    {cpu, bus} = CPU.step(cpu, bus)
    console = %{console | cpu: cpu, bus: bus}

    case bus.ppu.frame_ready do
      %{number: number} = frame when number > after_number -> {console, frame}
      _frame -> next_frame(console, after_number, remaining - 1)
    end
  end
end

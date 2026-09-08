defmodule Beamicom.GB.System do
  @moduledoc """
  Game Boy implementation of the coarse host system contract.

  DMG video uses one native shade-index byte per pixel. CGB video uses packed
  RGB24. Audio is not emitted until the APU core exists.
  """

  @behaviour Beamicom.Host.System

  alias Beamicom.GB.Machine
  alias Beamicom.Host.{Input, InputCapabilities, VideoFrame}

  @buttons ~w(up down left right a b start select)a
  @frame_dots 456 * 154
  @dot_rate 4_194_304
  @period_ns round(@frame_dots * 1_000_000_000 / @dot_rate)

  @impl true
  def id, do: :gbc

  @impl true
  def capabilities do
    %{
      media_extensions: [".gb", ".gbc"],
      input: InputCapabilities.new(%{1 => @buttons}),
      video: %{
        width: 160,
        height: 144,
        pixel_formats: [{:native, :dmg_shade_index}, :rgb24],
        frame_rate: @dot_rate / @frame_dots
      },
      audio: nil
    }
  end

  @impl true
  def load(media, opts \\ []), do: Machine.load(media, opts)

  @impl true
  def run_slice(%Machine{} = machine) do
    case Machine.run_until_frame(machine) do
      {:ok, machine, number, frame} ->
        video = %VideoFrame{
          system: :gbc,
          number: number,
          width: 160,
          height: 144,
          pixel_format: pixel_format(machine.model),
          data: frame,
          duration_ns: @period_ns,
          metadata: %{model: machine.model}
        }

        {machine, [video]}

      {:error, :frame_timeout, _machine} ->
        raise "Game Boy did not produce a frame"
    end
  end

  @impl true
  def set_input(%Machine{} = machine, %Input{port: 1, controls: controls}),
    do: Machine.set_buttons(machine, MapSet.to_list(controls))

  def set_input(%Machine{} = machine, %Input{}), do: machine

  defp pixel_format(:dmg), do: {:native, :dmg_shade_index}
  defp pixel_format(:cgb), do: :rgb24
end

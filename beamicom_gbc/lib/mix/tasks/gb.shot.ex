defmodule Mix.Tasks.Gb.Shot do
  @moduledoc """
  Runs a Game Boy ROM and writes a model-appropriate screenshot.

      mix gb.shot <rom.gb|rom.gbc> [out.png] [frames] [palette]

  Model selection follows the cartridge header. Defaults are `gb-shot.png`,
  two frames, and `dmg_green`; the palette argument applies to DMG frames only.
  Supported DMG palettes are `dmg_green` and `grayscale`.
  """

  @shortdoc "Render a ROM to a PNG screenshot"
  use Mix.Task

  alias Beamicom.GB.{Machine, PNG}

  @impl true
  def run(args) do
    Mix.Task.run("compile")

    case args do
      [rom | rest] -> capture(rom, rest)
      _args -> Mix.raise("usage: mix gb.shot <rom.gb|rom.gbc> [out.png] [frames] [palette]")
    end
  end

  defp capture(rom, rest) do
    output = Enum.at(rest, 0, "gb-shot.png")
    frames = parse_frames(Enum.at(rest, 1, "2"))
    palette = parse_palette(Enum.at(rest, 2, "dmg_green"))

    machine =
      rom
      |> File.read!()
      |> Machine.load()
      |> case do
        {:ok, machine} -> machine
        {:error, reason} -> Mix.raise("could not load #{rom}: #{inspect(reason)}")
      end

    {machine, number, frame} = run_frames(machine, frames)
    File.mkdir_p!(Path.dirname(Path.expand(output)))
    pixel_format = if machine.model == :cgb, do: :rgb24, else: :dmg_shade_index
    File.write!(output, PNG.encode(frame, palette: palette, pixel_format: pixel_format))

    detail = if machine.model == :cgb, do: "RGB24", else: "palette #{palette}"
    Mix.shell().info("wrote #{output} (frame #{number}, #{machine.model}, #{detail})")
  end

  defp run_frames(machine, count) do
    Enum.reduce(1..count, {machine, nil, nil}, fn _index, {machine, _number, _frame} ->
      case Machine.run_until_frame(machine) do
        {:ok, machine, number, frame} ->
          {machine, number, frame}

        {:error, :frame_timeout, _machine} ->
          Mix.raise("no frame rendered within instruction budget")
      end
    end)
  end

  defp parse_frames(value) do
    case Integer.parse(value) do
      {frames, ""} when frames > 0 -> frames
      _other -> Mix.raise("frames must be a positive integer")
    end
  end

  defp parse_palette("dmg_green"), do: :dmg_green
  defp parse_palette("grayscale"), do: :grayscale
  defp parse_palette(value), do: Mix.raise("unsupported palette: #{value}")
end

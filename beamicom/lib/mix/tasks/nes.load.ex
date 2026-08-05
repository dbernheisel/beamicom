defmodule Mix.Tasks.Nes.Load do
  @moduledoc """
  Load a save-state PNG and optionally run for more frames, dumping a screenshot.

      mix nes.load <state.png> [out.png] [more_frames]

  Defaults: out = resumed.png, more_frames = 0.
  Searches the directory containing state.png for a matching .nes if the ROM trailer
  was stripped. The output is a normal screenshot PNG proving the resume.
  """
  @shortdoc "Resume NES from a steganographic save PNG"
  use Mix.Task

  alias Beamicom.NES.{Console, Palette, PNG, ShareImage}

  @impl true
  def run(args) do
    Mix.Task.run("compile")
    [state_png | rest] = args
    out = Enum.at(rest, 0, "resumed.png")
    more_frames = String.to_integer(Enum.at(rest, 1, "0"))

    png_binary = File.read!(state_png)
    rom_dirs = [Path.dirname(state_png)]

    console =
      case ShareImage.load_image(png_binary, rom_dirs) do
        {:ok, c} -> c
        {:error, reason} -> Mix.raise("load failed: #{inspect(reason)}")
      end

    {_console, fb} =
      if more_frames > 0,
        do: run_frames(console, more_frames),
        else: {console, console.bus.ppu.frame_ready}

    unless fb, do: Mix.raise("no frame available after resume")

    File.write!(out, PNG.encode(fb.width, fb.height, Palette.to_rgb(fb)))
    Mix.shell().info("wrote #{out} (resumed at frame #{fb.number})")
  end

  defp run_frames(console, n) do
    Enum.reduce_while(1..20_000_000, {console, 0}, fn _, {c, count} ->
      c = Console.step(c)
      fb = c.bus.ppu.frame_ready

      if fb && count + 1 >= n,
        do: {:halt, {c, fb}},
        else: {:cont, {c, count + 1}}
    end)
    |> case do
      {c, %Beamicom.NES.Framebuffer{} = fb} -> {c, fb}
      {c, _} -> {c, nil}
    end
  end
end

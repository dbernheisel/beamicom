defmodule Mix.Tasks.Nes.Save do
  @moduledoc """
  Load a ROM, run it for a number of frames, and save a steganographic share image.

      mix nes.save <rom.nes> [out.png] [frames]

  Defaults: out = save.png, frames = 60.
  Saves at the first completed frame at or after `frames`.
  The PNG embeds the save state as a visible block-code frame around the screenshot,
  with the ROM blob appended as a trailer after IEND.
  """
  @shortdoc "Save NES state to a steganographic PNG"
  use Mix.Task

  alias Beamicom.NES.{Console, ShareImage}

  @impl true
  def run(args) do
    Mix.Task.run("compile")
    [rom | rest] = args
    out = Enum.at(rest, 0, "save.png")
    frames = String.to_integer(Enum.at(rest, 1, "60"))

    {console, fb} = run_until(Console.load(rom), frames)

    unless fb, do: Mix.raise("no frame rendered within budget")

    png = ShareImage.to_png(console, fb)
    File.write!(out, png)
    Mix.shell().info("wrote #{out} (frame #{fb.number}, #{byte_size(png)}B PNG)")
  end

  defp run_until(console, frames) do
    Enum.reduce_while(1..20_000_000, {console, nil}, fn _, {c, _} ->
      c = Console.step(c)
      fb = c.bus.ppu.frame_ready

      if fb && byte_size(fb.pixels) == fb.width * fb.height && fb.number >= frames,
        do: {:halt, {c, fb}},
        else: {:cont, {c, nil}}
    end)
    |> case do
      {c, %Beamicom.NES.Framebuffer{} = fb} -> {c, fb}
      _ -> {console, nil}
    end
  end
end

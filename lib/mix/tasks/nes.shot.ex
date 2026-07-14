defmodule Mix.Tasks.Nes.Shot do
  @moduledoc """
  Load a ROM, run it for a number of frames, and save a screenshot PNG.

      mix nes.shot <rom.nes> [out.png] [frames]

  Defaults: out = shot.png, frames = 60. Captures the first fully-rendered
  frame at or after `frames`.
  """
  @shortdoc "Render a ROM to a screenshot PNG"
  use Mix.Task

  alias Beamicom.NES.{Console, Palette, PNG}

  @impl true
  def run(args) do
    Mix.Task.run("compile")
    [rom | rest] = args
    out = Enum.at(rest, 0, "shot.png")
    frames = String.to_integer(Enum.at(rest, 1, "60"))

    fb = run_until(Console.load(rom), frames)

    unless fb, do: Mix.raise("no frame rendered within budget (is rendering enabled?)")

    File.write!(out, PNG.encode(fb.width, fb.height, Palette.to_rgb(fb)))
    Mix.shell().info("wrote #{out} (frame #{fb.number})")
  end

  defp run_until(console, frames) do
    Enum.reduce_while(1..20_000_000, console, fn _, c ->
      c = Console.step(c)
      fb = c.bus.ppu.frame_ready

      if fb && byte_size(fb.pixels) == fb.width * fb.height && fb.number >= frames,
        do: {:halt, fb},
        else: {:cont, c}
    end)
    |> case do
      %Beamicom.NES.Framebuffer{} = fb -> fb
      _ -> nil
    end
  end
end

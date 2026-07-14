defmodule Mix.Tasks.Nes.Wav do
  @moduledoc """
  Load a ROM, run it, and capture the APU output to a WAV file.

      mix nes.wav <rom.nes> [out.wav] [seconds]

  Defaults: out = out.wav, seconds = 3.
  """
  @shortdoc "Record a ROM's audio to a WAV"
  use Mix.Task

  alias Beamicom.NES.{APU, Console, WAV}

  @cpu_hz 1_789_773

  @impl true
  def run(args) do
    Mix.Task.run("compile")
    [rom | rest] = args
    out = Enum.at(rest, 0, "out.wav")
    seconds = String.to_float(Enum.at(rest, 1, "3.0") |> ensure_float())

    samples = capture(Console.load(rom), round(@cpu_hz * seconds), [])
    File.write!(out, WAV.encode(samples))
    Mix.shell().info("wrote #{out} (#{length(samples)} samples)")
  end

  defp ensure_float(s), do: if(String.contains?(s, "."), do: s, else: s <> ".0")

  # Step the console until its CPU has run `target` cycles, draining APU samples
  # in chunks to bound memory.
  defp capture(console, target, acc) do
    if console.cpu.cycles >= target do
      Enum.reverse(acc)
    else
      console = Enum.reduce(1..2000, console, fn _, c -> Console.step(c) end)
      {samples, apu} = APU.take_samples(console.bus.apu)
      capture(put_in(console.bus.apu, apu), target, prepend(acc, samples))
    end
  end

  defp prepend(acc, samples), do: Enum.reduce(samples, acc, &[&1 | &2])
end

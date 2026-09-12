defmodule NxNes.Reference do
  @moduledoc "Experiment-only public copies of private reference operations. No core files are edited."
  def load do
    for {file, name} <- [{"ppu", "PPU"}, {"apu", "APU"}] do
      source = File.read!(Path.expand("../../../../beamicom/lib/nes/#{file}.ex", __DIR__))

      source
      |> String.replace(
        "defmodule Beamicom.NES.#{name} do",
        "defmodule NxNes.Reference#{name} do"
      )
      |> String.replace("defp ", "def ")
      |> Code.compile_string("reference_#{file}.ex")
    end
  end
end

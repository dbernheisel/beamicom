defmodule Mix.Tasks.Nes.DumpFrameApu do
  @shortdoc "Compile and dump the platform-specific 48 kHz EXLA APU executable"
  @moduledoc """
  Usage:

      BEAMICOM_NX=1 BEAMICOM_AUDIO_48=1 mix nes.dump_frame_apu [--output PATH]

  Copy the resulting platform-specific file into the matching release and set
  `:beamicom_nes, :frame_apu_executable` to its path at boot.
  """

  use Mix.Task

  @impl true
  def run(arguments) do
    {options, positional, invalid} = OptionParser.parse(arguments, strict: [output: :string])

    if positional != [] or invalid != [], do: Mix.raise("expected only [--output PATH]")
    Mix.Task.run("app.start")

    unless Code.ensure_loaded?(Beamicom.NES.Nx.FrameAPUExecutable),
      do: Mix.raise("Nx/EXLA are unavailable; compile with BEAMICOM_NX=1")

    output = Keyword.get(options, :output, default_output())
    :ok = Beamicom.NES.Nx.FrameAPUExecutable.dump(output)
    Mix.shell().info("wrote platform-specific EXLA frame-APU executable to #{output}")
  end

  defp default_output do
    platform = :erlang.system_info(:system_architecture) |> List.to_string()
    Path.join([Mix.Project.app_path(), "priv", "exla", "nes_frame_apu_#{platform}.cache"])
  end
end

defmodule Mix.Tasks.Nes.DumpFrameVideo do
  @shortdoc "Compile and dump the platform-specific mapper-0 EXLA video executable"
  @moduledoc """
  Usage:

      BEAMICOM_NX=1 mix nes.dump_frame_video [--output PATH]

  The default output is under the current Mix build's priv/exla directory.
  Copy that platform-specific file into the matching release and configure
  :beamicom_nes, :frame_video_executable to its path at boot.
  """

  use Mix.Task

  @impl true
  def run(arguments) do
    {options, positional, invalid} = OptionParser.parse(arguments, strict: [output: :string])

    if positional != [] or invalid != [],
      do: Mix.raise("expected only [--output PATH]")

    Mix.Task.run("app.start")

    unless Code.ensure_loaded?(Beamicom.NES.Nx.FrameVideoExecutable),
      do: Mix.raise("Nx/EXLA are unavailable; compile with BEAMICOM_NX=1")

    output = Keyword.get(options, :output, default_output())
    :ok = Beamicom.NES.Nx.FrameVideoExecutable.dump(output)
    Mix.shell().info("wrote platform-specific EXLA frame-video executable to #{output}")
  end

  defp default_output do
    platform = :erlang.system_info(:system_architecture) |> List.to_string()
    Path.join([Mix.Project.app_path(), "priv", "exla", "nes_frame_video_#{platform}.cache"])
  end
end

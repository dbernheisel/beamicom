defmodule Beamicom.NES.Scenic do
  @moduledoc """
  Scenic local-verification client (spec §7): the on-your-machine window +
  speakers. `play/2` starts the emulation `Runtime` for a ROM, opens the Scenic
  window (`Beamicom.NES.Scenic.Screen`, which reads frames from `Beamicom.NES.Output`), and starts
  the local `Beamicom.NES.AudioSink` (ffplay). These outputs are the *local* client's
  choice — the Phoenix client would push A/V over a socket, GStreamer through a
  pipeline — so they live in this project, not in the core emulator (`beamicom`).

  Requires the native driver: GLFW must be installed (see the README).

      iex> Beamicom.NES.Scenic.play("roms/game.nes")
      iex> Beamicom.NES.Scenic.play("roms/game.nes", scale: 4)
  """

  @doc "Load a ROM and open the Scenic window + audio (integer `:scale`, default 3)."
  def play(rom, opts \\ []) do
    scale = Keyword.get(opts, :scale, 3)
    # Audio is best-effort: the sink declines (`:ignore`) if ffplay is missing.
    case Beamicom.NES.AudioSink.start_link([]) do
      {:ok, _pid} -> :ok
      :ignore -> :ok
      error -> raise(inspect(error))
    end
    {:ok, _} = Beamicom.NES.Runtime.start_link(rom: rom)

    config =
      Application.get_env(:beamicom_scenic, :viewport)
      |> Keyword.put(:size, {256 * scale, 240 * scale})
      |> Keyword.put(:default_scene, {Beamicom.NES.Scenic.Screen, scale: scale})

    {:ok, _} = Scenic.start_link([config])
    :ok
  end
end

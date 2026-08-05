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
      iex> Beamicom.NES.Scenic.play("save.png")
  """

  @doc """
  Load a ROM **or** a beamicom save PNG and open the Scenic window + audio.

  The file is sniffed by its magic bytes: a `.nes` ROM boots fresh, a save PNG
  (produced by `mix nes.save`) resumes the saved console.

  Options: integer `:scale` (default 3); `:speed` (default 1.0) — a playback
  multiplier below 1.0 runs the whole machine in glitch-free slow motion (audio
  and video stay in sync) for hosts that can't sustain real-time. The emulator
  and the audio sink are paced to the same `:speed`, so `0.5` = half-speed with
  pitch preserved.

  `:audio_slices` (default 2) delivers audio in that many sub-frame chunks to cut
  A/V lag — 2 roughly halves the audio trail, higher tightens it further. Raise
  it only while the machine has slack: if audio starts cutting out, lower it.
  """
  def play(path, opts \\ []) do
    scale = Keyword.get(opts, :scale, 3)
    speed = Keyword.get(opts, :speed, 1.0)
    slices = Keyword.get(opts, :audio_slices, 2)
    # Audio is best-effort: the sink declines (`:ignore`) if ffplay is missing.
    case Beamicom.NES.AudioSink.start_link(speed: speed) do
      {:ok, _pid} -> :ok
      :ignore -> :ok
      error -> raise(inspect(error))
    end

    {:ok, _} =
      Beamicom.NES.Runtime.start_link([speed: speed, audio_slices: slices] ++ source_opts(path))

    # Extra height below the game for the control bar (Save button), so it never
    # overlaps the screen.
    config =
      Application.get_env(:beamicom_scenic, :viewport)
      |> Keyword.put(
        :size,
        {256 * scale, 240 * scale + Beamicom.NES.Scenic.Screen.controls_height()}
      )
      |> Keyword.put(:default_scene, {Beamicom.NES.Scenic.Screen, scale: scale})

    {:ok, _} = Scenic.start_link([config])
    :ok
  end

  # Sniff the file by magic bytes: a .nes ROM boots fresh; a beamicom save PNG
  # resumes the saved console (ROM pulled from the PNG trailer, or matched by CRC
  # against .nes files next to it).
  defp source_opts(path) do
    case File.read!(path) do
      <<"NES", 0x1A, _::binary>> ->
        [rom: path]

      <<137, 80, 78, 71, 13, 10, 26, 10, _::binary>> = png ->
        case Beamicom.NES.ShareImage.load_image(png, [Path.dirname(path)]) do
          {:ok, console} -> [console: console]
          {:error, reason} -> raise "#{path}: could not load save (#{inspect(reason)})"
        end

      _ ->
        raise ArgumentError, "#{path}: not a .nes ROM or a beamicom save PNG"
    end
  end
end

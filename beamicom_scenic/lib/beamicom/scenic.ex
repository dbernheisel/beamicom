defmodule Beamicom.Scenic do
  @moduledoc """
  Local Scenic window, keyboard controls, and audio for Beamicom cores.

  `.nes`, `.gb`, and `.gbc` files are selected by extension. Existing NES save
  PNGs are also accepted. The emulator cores remain independent of Scenic.

      Beamicom.Scenic.play("roms/game.nes")
      Beamicom.Scenic.play("roms/game.nes", video_filter: :composite, scale: 1)
      Beamicom.Scenic.play("roms/game.gbc", video_filter: :pixel_transparency, scale: 4)
  """

  alias Beamicom.Scenic.Player

  @doc """
  Load supported media and start the single local Scenic player.

  Options include `:scale` (default 3, or 1 for an NES NTSC filter), positive
  `:speed` (default 1.0), `:audio` (default true), `:audio_command` for overriding
  the external player, and core-specific `:load_options`. Scale is normally an
  integer; the Game Boy Pixel Transparency filter also accepts fractional values
  greater than one.

  NES accepts a runtime `:video_filter` of `:native`, `:composite`, `:svideo`,
  `:rgb`, or `:monochrome`. Pass Blargg filter setup overrides with
  `:video_filter_options`.

  Game Boy and Game Boy Color accept `:pixel_transparency`; `:native` selects
  the default nearest-neighbor presentation scaler. Shader overrides use
  `:video_filter_options`.

  `:audio_slices` applies only to NES and defaults to one whole frame; higher
  values reduce audio queue granularity but add scheduling overhead. Game Boy
  emits one audio chunk at each frame boundary. `:pace` defaults to true for
  both systems.
  """
  def play(path, options \\ []) when is_binary(path) and is_list(options) do
    case Player.start(path: path, options: options) do
      {:ok, _player} ->
        :ok

      {:error, {:already_started, _player}} ->
        raise ArgumentError, "Beamicom Scenic is already running"

      {:error, reason} ->
        raise ArgumentError, format_error(path, reason)
    end
  end

  @doc "Stop the running Scenic player and all processes it owns."
  def stop do
    case Process.whereis(Player) do
      nil -> :ok
      _pid -> GenServer.stop(Player)
    end
  end

  @doc "Return the active media/core profile, or `{:error, :not_running}`."
  def status do
    case Process.whereis(Player) do
      nil -> {:error, :not_running}
      _pid -> Player.status()
    end
  end

  defp format_error(path, {:unsupported_media_extension, extension}),
    do:
      "#{path}: unsupported media extension #{inspect(extension)}; expected .nes, .gb, .gbc, or an NES save .png"

  defp format_error(path, {:invalid_option, option}), do: "#{path}: invalid #{option} option"

  defp format_error(path, {:save_load_failed, reason}),
    do: "#{path}: could not load NES save (#{inspect(reason)})"

  defp format_error(path, reason), do: "#{path}: #{inspect(reason)}"
end

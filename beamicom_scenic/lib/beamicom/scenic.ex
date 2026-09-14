defmodule Beamicom.Scenic do
  @moduledoc """
  Local Scenic window, keyboard controls, and audio for Beamicom cores.

  `.nes`, `.gb`, `.gbc`, `.sfc`, and `.smc` files are selected by extension. Existing NES save
  PNGs are also accepted. The emulator cores remain independent of Scenic.

      Beamicom.Scenic.play("roms/game.nes")
      Beamicom.Scenic.play("roms/game.nes", video_filter: :composite, scale: 1)
      Beamicom.Scenic.play("roms/game.gbc", video_filter: :pixel_transparency, scale: 4)
  """

  alias Beamicom.Scenic.Host

  @doc "Start the Scenic shell without loading media. Safe to call repeatedly."
  def start do
    case Host.start() do
      {:ok, _host} -> :ok
      {:error, {:already_started, _host}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Load supported media and start the single local Scenic player.

  Options include `:scale` (used by flexible scaling; default 3, or 1 for an NES
  NTSC filter), positive `:speed` (default 1.0), `:audio` (default true),
  `:audio_command` for overriding the external player, and core-specific
  `:load_options`. Scale is normally an integer; the Game Boy Pixel Transparency
  filter also accepts fractional values greater than one. When persisted integer
  scaling is enabled, the viewport chooses the largest complete native-size stage
  that fits instead.

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
    with :ok <- start(), :ok <- Host.load(path, options) do
      :ok
    else
      {:error, :already_running} ->
        raise ArgumentError, "Beamicom Scenic is already running"

      {:error, reason} ->
        raise ArgumentError, format_error(path, reason)
    end
  end

  @doc "Replace the active session, or load one if the shell is idle."
  def replace(path, options \\ []) when is_binary(path) and is_list(options) do
    with :ok <- start() do
      Host.replace(path, options)
    end
  end

  @doc "Pause the active emulator session and clear held controller input."
  def pause, do: session_call(&Host.pause/0)

  @doc "Resume the active emulator session."
  def resume, do: session_call(&Host.resume/0)

  @doc "Recreate the active emulator session from its current media and options."
  def reset, do: session_call(&Host.reset/0)

  @doc "Stop the active emulator session while leaving the Scenic shell open."
  def unload, do: session_call(&Host.unload/0)

  @doc "Stop the Scenic shell and its active emulator session."
  def stop do
    case Process.whereis(Host) do
      nil -> :ok
      _pid -> Host.stop()
    end
  end

  @doc "Return the shell and active-session status, or `{:error, :not_running}`."
  def status do
    case Process.whereis(Host) do
      nil -> {:error, :not_running}
      _pid -> Host.status()
    end
  end

  defp session_call(fun) do
    case Process.whereis(Host) do
      nil -> {:error, :not_running}
      _pid -> fun.()
    end
  end

  defp format_error(path, {:unsupported_media_extension, extension}),
    do:
      "#{path}: unsupported media extension #{inspect(extension)}; expected .nes, .gb, .gbc, .sfc, .smc, or a save .png"

  defp format_error(path, {:invalid_option, option}), do: "#{path}: invalid #{option} option"

  defp format_error(path, {:save_load_failed, reason}),
    do: "#{path}: could not load NES save (#{inspect(reason)})"

  defp format_error(path, reason), do: "#{path}: #{inspect(reason)}"
end

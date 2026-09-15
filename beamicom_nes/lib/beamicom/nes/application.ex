defmodule Beamicom.NES.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        # A/V output fan-out hub; the Runtime loop is started on demand per ROM.
        Beamicom.NES.Output
      ] ++ frame_video_loader() ++ frame_apu_loader()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Beamicom.NES.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp frame_video_loader do
    case Application.get_env(:beamicom_nes, :frame_video_executable) do
      path when is_binary(path) ->
        if Code.ensure_loaded?(Beamicom.NES.Nx.FrameVideoExecutable),
          do: [{Beamicom.NES.Nx.FrameVideoExecutable, path: path}],
          else: []

      _ ->
        []
    end
  end

  defp frame_apu_loader do
    case Application.get_env(:beamicom_nes, :frame_apu_executable) do
      path when is_binary(path) ->
        if Code.ensure_loaded?(Beamicom.NES.Nx.FrameAPUExecutable),
          do: [{Beamicom.NES.Nx.FrameAPUExecutable, path: path}],
          else: []

      _ ->
        []
    end
  end
end

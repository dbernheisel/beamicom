defmodule BeamicomPhx.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        BeamicomPhxWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:beamicom_phx, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: BeamicomPhx.PubSub},
        BeamicomPhxWeb.Endpoint
      ] ++ emulator_children()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: BeamicomPhx.Supervisor]
    result = Supervisor.start_link(children, opts)
    maybe_load_boot_rom()
    result
  end

  # server mode => run the emulator supervisor (Beamicom.NES.Output is started by
  # the :beamicom app; the Runtime is loaded on demand via BeamicomPhx.Emulator,
  # at boot from BEAMICOM_ROM or later from a drag-and-dropped ROM). The RtpBroadcast
  # pipeline (when a relay target is set) subscribes to Output and simply waits for
  # frames, so it no longer depends on a ROM being present at boot.
  defp emulator_children do
    case Application.get_env(:beamicom_phx, :mode, :server) do
      :server -> [BeamicomPhx.Emulator] ++ rtp_broadcast_children()
      :client -> [{BeamicomPhx.AV.Relay, listen_port: BeamicomPhx.RtpConfig.listen_port()}]
      _ -> []
    end
  end

  # Load the ROM named by BEAMICOM_ROM at boot, if server mode and one is set.
  # Runs after the supervisor (and thus BeamicomPhx.Emulator) has started.
  defp maybe_load_boot_rom do
    with :server <- Application.get_env(:beamicom_phx, :mode, :server),
         rom when is_binary(rom) <- Application.get_env(:beamicom_phx, :rom) do
      BeamicomPhx.Emulator.load(rom)
    else
      _ -> :ok
    end
  end

  defp rtp_broadcast_children do
    case BeamicomPhx.RtpConfig.target() do
      nil ->
        []

      target ->
        [
          %{
            id: BeamicomPhx.AV.RtpBroadcast,
            start:
              {Membrane.Pipeline, :start_link, [BeamicomPhx.AV.RtpBroadcast, [target: target]]}
          }
        ]
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BeamicomPhxWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

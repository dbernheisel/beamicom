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

  # Server mode runs the session coordinator and its temporary runtime/output/
  # broadcaster supervisor. NES borrows Beamicom.NES.Output; Game Boy owns a
  # private Host.Output for the lifetime of that family session.
  defp emulator_children do
    case Application.get_env(:beamicom_phx, :mode, :server) do
      :server ->
        [
          {DynamicSupervisor, name: BeamicomPhx.RuntimeSupervisor, strategy: :one_for_one},
          BeamicomPhx.Emulator
        ] ++ ei_children() ++ [BeamicomPhx.PlayerQueue]

      :client ->
        [{BeamicomPhx.AV.Relay, listen_port: BeamicomPhx.RtpConfig.listen_port()}]

      _ ->
        []
    end
  end

  defp ei_children do
    path = Beamicom.EI.default_path()

    [
      %{
        id: BeamicomPhx.EIServer,
        start:
          {Beamicom.EI.Server, :start_link,
           [
             [
               name: BeamicomPhx.EIServer,
               path: path,
               on_buttons: &BeamicomPhx.Emulator.press/2
             ]
           ]}
      },
      %{
        id: BeamicomPhx.EIClient,
        start:
          {Beamicom.EI.Client, :start_link,
           [[registered_name: BeamicomPhx.EIClient, name: "beamicom-phx", path: path]]}
      }
    ]
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

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BeamicomPhxWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

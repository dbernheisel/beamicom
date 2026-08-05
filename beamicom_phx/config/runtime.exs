import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/beamicom_phx start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :beamicom_phx, BeamicomPhxWeb.Endpoint, server: true
end

mode =
  case System.get_env("BEAMICOM_MODE", "server") do
    "client" -> :client
    _ -> :server
  end

port =
  case {System.get_env("PORT"), mode} do
    {port, _} when not is_nil(port) -> String.to_integer(port)
    {_, :server} -> 4044
    {_, :client} -> 4046
  end

config :beamicom_phx, BeamicomPhxWeb.Endpoint, http: [port: port]

# Beamicom mode: "server" runs the emulator and streams it; "client" (Phase 2)
# relays a remote server. Watch-only Phase 1 supports server mode only.
# Explicit map (not String.to_atom) — never intern atoms from env/user input.
config :beamicom_phx, :mode, mode

# Where save-state PNGs are stored and read at runtime. Defaults to the XDG data
# directory ($XDG_DATA_HOME/beamicom/saves, falling back to ~/.local/share).
config :beamicom_phx,
       :saves_dir,
       System.get_env("BEAMICOM_SAVES_DIR") ||
         Path.join([
           System.get_env("XDG_DATA_HOME") || Path.join(System.user_home!(), ".local/share"),
           "beamicom",
           "saves"
         ])

# Absolute path to a .nes ROM the server should run. If unset in server mode,
# the app still boots but the emulator does not start (log a warning).
if mode == :server and config_env() != :test do
  config :beamicom_phx,
         :rom,
         System.get_env("BEAMICOM_ROM") ||
           raise("server mode requires BEAMICOM_ROM to be supplied")

  parse_target =
    fn
      nil ->
        nil

      "" ->
        nil

      target when is_binary(target) ->
        with [host, port] <- String.split(target, ":"),
             {:ok, ip} <- :inet.parse_address(String.to_charlist(host)),
             {port, ""} <- Integer.parse(port) do
          {ip, port}
        else
          _ ->
            raise ArgumentError,
                  "invalid BEAMICOM_RTP_TARGET #{inspect(target)}, expected host:port"
        end
    end

  config :beamicom_phx, :rtp_target, parse_target.(System.get_env("BEAMICOM_RTP_TARGET"))
end

if mode == :client and config_env() != :test do
  config :beamicom_phx,
         :rtp_listen,
         String.to_integer(System.get_env("BEAMICOM_RTP_LISTEN", "5000"))
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :beamicom_phx, BeamicomPhxWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$"E,
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/beamicom_phx_web/router\.ex$"E,
        ~r"lib/beamicom_phx_web/(controllers|live|components)/.*\.(ex|heex)$"E
      ]
    ]
end

if config_env() == :prod do
  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :beamicom_phx, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :beamicom_phx, BeamicomPhxWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :beamicom_phx, BeamicomPhxWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :beamicom_phx, BeamicomPhxWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end

# Beamicom EI

`beamicom_ei` is an implementation of the EI input protocol over a
Unix-domain socket. It provides a server that publishes one or two virtual
controllers and a client that sends complete button state.

The public modules retain the `Beamicom.EI` namespace:

- `Beamicom.EI.Server` accepts EI clients and reports committed button changes.
- `Beamicom.EI.Client` connects to an EI server and sends button state.
- `Beamicom.EI` provides the default socket path.

## Usage

Add the sibling project as a path dependency:

```elixir
{:beamicom_ei, path: "../beamicom_ei"}
```

Start a server and connect a client:

```elixir
{:ok, server} =
  Beamicom.EI.Server.start_link(
    path: Beamicom.EI.default_path(),
    on_buttons: fn port, buttons -> IO.inspect({port, buttons}) end
  )

{:ok, client} = Beamicom.EI.Client.start_link(path: Beamicom.EI.Server.path(server))
:ok = Beamicom.EI.Client.await_ready(client)
:ok = Beamicom.EI.Client.set_buttons(client, 1, [:right, :a])
```

Both sides default to controller ports `[1, 2]`. Pass `ports: [1]` to both the
server and client for a single-controller system such as Game Boy or Game Boy
Color. Supported buttons are `:up`, `:down`, `:left`, `:right`, `:a`, `:b`,
`:select`, and `:start`.

The server socket is created with mode `0600`. Button changes are published on
`ei_device.frame`, and disconnecting a client releases that client's held
buttons.

## Tests

```sh
mix test
```

# Beamicom EI

`beamicom_ei` is an implementation of the EI input protocol over a
Unix-domain socket. It provides a server that publishes one or two virtual
controllers, a client that sends complete button state, and an optional SDL
adapter for physical controllers.

The public modules retain the `Beamicom.EI` namespace:

- `Beamicom.EI.Server` accepts EI clients and reports committed button changes.
- `Beamicom.EI.Client` connects to an EI server and sends button state.
- `Beamicom.EI.Gamepad` reads SDL-compatible USB and Bluetooth controllers and
  sends their complete state through a dedicated client.
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

{:ok, gamepad} =
  Beamicom.EI.Gamepad.start_link(
    path: Beamicom.EI.Server.path(server),
    ports: [1, 2]
  )
```

Both sides default to controller ports `[1, 2]`. Pass `ports: [1]` to both the
server and client for a single-controller system such as Game Boy or Game Boy
Color. Supported buttons are `:up`, `:down`, `:left`, `:right`, `:a`, `:b`,
`:x`, `:y`, `:l`, `:r`, `:select`, and `:start`.

The server socket is created with mode `0600`. Button changes are published on
`ei_device.frame`, and disconnecting a client releases that client's held
buttons.

## Physical controllers

When `pkg-config` can find SDL2, compilation also builds the external
`gamepad_input` Port program. No native code is loaded into the BEAM. The D-pad
and left stick control direction, while SDL's standardized A/B/X/Y, shoulder,
Back, and Start buttons map to the matching EI buttons.

Controllers are assigned in connection order to the requested `ports`. Extra
controllers wait and are promoted when an assigned controller disconnects.
Because the adapter is part of `beamicom_ei`, Scenic, V4L2, streaming, and other
frontends can start it against their EI server without duplicating device
handling. If SDL2 is unavailable, the project still compiles and
`Beamicom.EI.Gamepad.start_link/1` returns `:ignore` unless an explicit helper
command is provided.

## Tests

```sh
mix test
```

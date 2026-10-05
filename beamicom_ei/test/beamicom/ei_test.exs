defmodule Beamicom.EITest do
  use ExUnit.Case, async: true
  alias Beamicom.EI.{Client, Codec, Codes, Server}

  test "uses Linux evdev codes for SNES buttons" do
    assert Codes.code(:x) == {:ok, 0x133}
    assert Codes.code(:y) == {:ok, 0x134}
    assert Codes.code(:l) == {:ok, 0x136}
    assert Codes.code(:r) == {:ok, 0x137}
    assert Codes.code(:select) == {:ok, 0x13A}

    assert Enum.map([0x133, 0x134, 0x136, 0x137], &Codes.button/1) == [:x, :y, :l, :r]
  end

  test "codec preserves partial and coalesced EI messages" do
    first = Codec.message(7, 2, Codec.u32(42))
    second = Codec.message(8, 3, Codec.string("hello"))
    <<head::binary-size(10), tail::binary>> = first <> second
    assert {[], ^head} = Codec.decode(head)
    assert {[{7, 2, _}, {8, 3, args}], <<>>} = Codec.decode(head <> tail)
    assert {"hello", <<>>} = Codec.take_string(args)
  end

  @tag :tmp_dir
  test "commits", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "s")
    owner = self()

    server =
      start_supervised!({Server, path: path, on_buttons: fn p, b -> send(owner, {p, b}) end})

    client = start_supervised!({Client, path: path, name: "test"})
    assert :ok = Client.await_ready(client)
    assert Server.path(server) == path
    assert :ok = Client.set_buttons(client, 1, [:right, :a, :x, :y, :l, :r, :select])

    assert_receive {1, buttons}
    assert MapSet.new(buttons) == MapSet.new([:right, :a, :x, :y, :l, :r, :select])

    assert :ok = Client.set_buttons(client, 1, [])
    assert_receive {1, []}
  end

  @tag :tmp_dir
  test "disconnect", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "s")
    owner = self()
    start_supervised!({Server, path: path, on_buttons: fn p, b -> send(owner, {p, b}) end})
    client = start_supervised!({Client, path: path})
    :ok = Client.await_ready(client)
    :ok = Client.set_buttons(client, 2, [:start])
    assert_receive {2, [:start]}
    stop_supervised(Client)
    assert_receive {2, []}
  end

  @tag :tmp_dir
  test "handheld", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "s")
    owner = self()

    start_supervised!(
      {Server,
       path: path, ports: [1], on_buttons: fn port, buttons -> send(owner, {port, buttons}) end}
    )

    client = start_supervised!({Client, path: path, ports: [1]})
    assert :ok = Client.await_ready(client)
    assert :ok = Client.set_buttons(client, 1, [:a])
    assert_receive {1, [:a]}
    assert {:error, :not_ready} = Client.set_buttons(client, 2, [:a])
  end
end

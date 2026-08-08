defmodule Beamicom.EITest do
  use ExUnit.Case, async: true
  alias Beamicom.EI.{Client, Codec, Server}

  test "codec preserves partial and coalesced EI messages" do
    first = Codec.message(7, 2, Codec.u32(42))
    second = Codec.message(8, 3, Codec.string("hello"))
    <<head::binary-size(10), tail::binary>> = first <> second
    assert {[], ^head} = Codec.decode(head)
    assert {[{7, 2, _}, {8, 3, args}], <<>>} = Codec.decode(head <> tail)
    assert {"hello", <<>>} = Codec.take_string(args)
  end

  @tag :tmp_dir
  test "commits buttons", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "beamicom-ei.sock")
    owner = self()

    server =
      start_supervised!({Server, path: path, on_buttons: fn p, b -> send(owner, {p, b}) end})

    client = start_supervised!({Client, path: path, name: "test"})
    assert :ok = Client.await_ready(client)
    assert Server.path(server) == path
    assert :ok = Client.set_buttons(client, 1, [:right, :a])
    assert_receive {1, [:a, :right]}
    assert :ok = Client.set_buttons(client, 1, [])
    assert_receive {1, []}
  end

  @tag :tmp_dir
  test "releases on disconnect", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "beamicom-ei.sock")
    owner = self()
    start_supervised!({Server, path: path, on_buttons: fn p, b -> send(owner, {p, b}) end})
    client = start_supervised!({Client, path: path})
    :ok = Client.await_ready(client)
    :ok = Client.set_buttons(client, 2, [:start])
    assert_receive {2, [:start]}
    stop_supervised(Client)
    assert_receive {2, []}
  end
end

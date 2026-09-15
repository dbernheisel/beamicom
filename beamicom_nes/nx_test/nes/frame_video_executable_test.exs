defmodule Beamicom.NES.Nx.FrameVideoExecutableTest do
  use ExUnit.Case, async: false

  alias Beamicom.NES.Nx.FrameVideoExecutable

  test "release dump uses EXLA disk format and reloads it" do
    path =
      Path.join(
        System.tmp_dir!(),
        "beamicom-frame-video-#{System.unique_integer([:positive])}.cache"
      )

    on_exit(fn -> File.rm(path) end)

    assert :ok = FrameVideoExecutable.dump(path)
    assert <<"EXLA", 1, _::binary>> = File.read!(path)
    assert {:ok, compiled, :disk} = FrameVideoExecutable.load(path)
    assert is_function(compiled, 6)
  end

  test "missing or corrupt dumps compile on first use" do
    missing =
      Path.join(System.tmp_dir!(), "beamicom-missing-#{System.unique_integer([:positive])}.cache")

    corrupt =
      Path.join(System.tmp_dir!(), "beamicom-corrupt-#{System.unique_integer([:positive])}.cache")

    File.write!(corrupt, "not an EXLA dump")

    on_exit(fn ->
      File.rm(missing)
      File.rm(corrupt)
    end)

    assert {:ok, missing_fun, :compiled} = FrameVideoExecutable.load(missing)
    assert is_function(missing_fun, 6)
    assert File.regular?(missing)

    assert {:ok, fallback_fun, :fallback_compiled} = FrameVideoExecutable.load(corrupt)
    assert is_function(fallback_fun, 6)
  end

  test "boot loader keeps the loaded executable available without a server call" do
    path =
      Path.join(System.tmp_dir!(), "beamicom-boot-#{System.unique_integer([:positive])}.cache")

    name = :"frame-video-loader-#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm(path) end)
    start_supervised!({FrameVideoExecutable, path: path, name: name})

    args = blank_arguments()
    {frame, overflow, hit} = FrameVideoExecutable.render(args, name)
    assert Nx.shape(frame) == {240, 256}
    assert Nx.to_number(overflow) == 0
    assert Nx.to_number(hit) == -1
  end

  defp blank_arguments do
    [
      Nx.broadcast(Nx.tensor(0, type: :u8), {2048}),
      Nx.from_binary(:binary.copy(<<0xFF, 0, 0, 0>>, 64), :u8),
      Nx.broadcast(Nx.tensor(0, type: :u8), {512, 8, 8}),
      Nx.broadcast(Nx.tensor(0, type: :s32), {256, 3}),
      Nx.tensor(0, type: :s32),
      Nx.tensor([0, 0, 0, 0, 0, 1, 0], type: :s32)
    ]
  end
end

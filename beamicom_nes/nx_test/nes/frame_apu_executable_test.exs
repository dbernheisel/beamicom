defmodule Beamicom.NES.Nx.FrameAPUExecutableTest do
  use ExUnit.Case, async: false

  alias Beamicom.NES.Nx.FrameAPUExecutable

  test "release dump uses EXLA disk format and reloads donated templates" do
    path =
      Path.join(
        System.tmp_dir!(),
        "beamicom-frame-apu-#{System.unique_integer([:positive])}.cache"
      )

    on_exit(fn -> File.rm(path) end)

    assert :ok = FrameAPUExecutable.dump(path)
    assert <<"EXLA", 1, _::binary>> = File.read!(path)
    assert {:ok, compiled, :disk} = FrameAPUExecutable.load(path)
    assert is_function(compiled, 6)
  end

  test "missing and corrupt dumps compile safely" do
    missing =
      Path.join(
        System.tmp_dir!(),
        "beamicom-frame-apu-missing-#{System.unique_integer([:positive])}.cache"
      )

    corrupt =
      Path.join(
        System.tmp_dir!(),
        "beamicom-frame-apu-corrupt-#{System.unique_integer([:positive])}.cache"
      )

    File.write!(corrupt, "not an EXLA dump")

    on_exit(fn ->
      File.rm(missing)
      File.rm(corrupt)
    end)

    assert {:ok, missing_fun, :compiled} = FrameAPUExecutable.load(missing)
    assert is_function(missing_fun, 6)
    assert File.regular?(missing)

    assert {:ok, fallback_fun, :fallback_compiled} = FrameAPUExecutable.load(corrupt)
    assert is_function(fallback_fun, 6)
  end

  test "boot loader publishes the loaded function through persistent term" do
    path =
      Path.join(
        System.tmp_dir!(),
        "beamicom-frame-apu-boot-#{System.unique_integer([:positive])}.cache"
      )

    name = :"frame-apu-loader-#{System.unique_integer([:positive])}"
    on_exit(fn -> File.rm(path) end)
    start_supervised!({FrameAPUExecutable, path: path, name: name})
    assert is_function(FrameAPUExecutable.loaded(name), 6)
  end
end

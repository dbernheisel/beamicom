defmodule BeamicomV4L2.Native do
  @moduledoc false

  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :beamicom_v4l2,
    crate: "beamicom_v4l2_nif",
    base_url:
      "https://github.com/dbernheisel/beamicom/releases/download/beamicom_v4l2-v#{version}",
    version: version,
    force_build: System.get_env("BEAMICOM_V4L2_BUILD") in ["1", "true"],
    nif_versions: ["2.15"],
    targets: [
      "aarch64-unknown-linux-gnu",
      "aarch64-unknown-linux-musl",
      "arm-unknown-linux-gnueabihf",
      "x86_64-unknown-linux-gnu",
      "x86_64-unknown-linux-musl"
    ]

  def start(_framebuffer, _output, _fps, _x, _y, _width, _height),
    do: :erlang.nif_error(:nif_not_loaded)

  def stop(_resource), do: :erlang.nif_error(:nif_not_loaded)
  def status(_resource), do: :erlang.nif_error(:nif_not_loaded)
  def keyboard_open(_paths), do: :erlang.nif_error(:nif_not_loaded)
  def keyboard_read(_resource), do: :erlang.nif_error(:nif_not_loaded)
end

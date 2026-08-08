defmodule BeamicomV4L2.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/dbernheisel/beamicom"

  def project do
    [
      app: :beamicom_v4l2,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      description: "Stream a Linux framebuffer into a V4L2 output device",
      source_url: @source_url,
      package: package(),
      deps: deps(),
      aliases: aliases()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:beamicom, path: "../beamicom"},
      {:rustler_precompiled, "~> 0.9"},
      {:rustler, "~> 0.38", optional: true}
    ]
  end

  defp aliases do
    [{:"test.rust", [&rust_checks/1]}]
  end

  defp rust_checks(_arguments) do
    manifest = "native/beamicom_v4l2_nif/Cargo.toml"

    run_rust!(~w(fmt --manifest-path #{manifest} --check))
    run_rust!(~w(clippy --manifest-path #{manifest} --all-targets -- -D warnings))
    run_rust!(~w(test --manifest-path #{manifest}))
  end

  defp run_rust!(arguments) do
    {output, status} =
      System.cmd("mise", ["exec", "--", "cargo" | arguments], stderr_to_stdout: true)

    IO.write(output)
    if status != 0, do: Mix.raise("cargo #{hd(arguments)} failed with status #{status}")
  end

  defp package do
    [
      files: [
        "lib",
        "native/beamicom_v4l2_nif/.cargo",
        "native/beamicom_v4l2_nif/src",
        "native/beamicom_v4l2_nif/Cargo*",
        "checksum-*.exs",
        "mix.exs",
        "README.md"
      ],
      links: %{"GitHub" => @source_url}
    ]
  end
end

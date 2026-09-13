defmodule BeamicomNES.MixProject do
  use Mix.Project

  def project do
    [
      app: :beamicom_nes,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {Beamicom.NES.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  # The core emulator has no third-party dependencies. Its system-neutral host
  # contract is the sibling `beamicom_host` project.
  defp deps do
    [{:beamicom_host, path: "../beamicom_host"}]
  end
end

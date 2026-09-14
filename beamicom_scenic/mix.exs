defmodule BeamicomScenic.MixProject do
  use Mix.Project

  def project do
    [
      app: :beamicom_scenic,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make] ++ Mix.compilers(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:beamicom_nes, path: "../beamicom_nes"},
      {:beamicom_gbc, path: "../beamicom_gbc"},
      {:beamicom_snes, path: "../beamicom_snes"},
      {:nx, "~> 1.0"},
      {:exla, "~> 1.0"},
      {:beamicom_host, path: "../beamicom_host"},
      {:beamicom_ei, path: "../beamicom_ei"},
      {:scenic, "~> 0.11"},
      {:scenic_driver_local, "~> 0.11"},
      {:elixir_make, "~> 0.7", runtime: false}
    ]
  end
end

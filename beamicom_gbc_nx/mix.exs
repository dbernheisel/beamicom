defmodule BeamicomGBCNx.MixProject do
  use Mix.Project

  def project do
    [
      app: :beamicom_gbc_nx,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps: [
        {:beamicom_gbc, path: "../beamicom_gbc"},
        {:nx, "~> 1.0"},
        {:exla, "~> 1.0"}
      ]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {Beamicom.GB.Nx.Application, []}]
  end
end

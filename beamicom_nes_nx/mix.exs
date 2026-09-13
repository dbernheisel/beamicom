defmodule BeamicomNESNx.MixProject do
  use Mix.Project

  def project do
    [
      app: :beamicom_nes_nx,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps: [
        {:beamicom_nes, path: "../beamicom_nes"},
        {:nx, "~> 1.0"},
        {:exla, "~> 1.0"}
      ]
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {Beamicom.NES.Nx.Application, []}]
  end
end

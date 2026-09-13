defmodule BeamicomGBC.MixProject do
  use Mix.Project

  def project do
    [
      app: :beamicom_gbc,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: [
        {:beamicom_host, path: "../beamicom_host"},
        {:beamicom_ei, path: "../beamicom_ei"},
        {:nx, "~> 1.0", optional: true},
        {:exla, "~> 1.0", optional: true}
      ]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end
end

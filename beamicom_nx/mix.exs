defmodule BeamicomNx.MixProject do
  use Mix.Project

  def project do
    [
      app: :beamicom_nx,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps: [
        {:beamicom, path: "../beamicom"},
        {:nx, "~> 1.0"},
        {:exla, "~> 1.0"}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end

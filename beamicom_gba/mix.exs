defmodule BeamicomGBA.MixProject do
  use Mix.Project

  def project do
    [
      app: :beamicom_gba,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      test_ignore_filters: [~r{(^|/)support/}],
      deps: [
        {:beamicom_host, path: "../beamicom_host"},
        {:nx, "~> 1.0", optional: true},
        {:exla, "~> 1.0", optional: true}
      ]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end

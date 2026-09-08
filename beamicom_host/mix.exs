defmodule BeamicomHost.MixProject do
  use Mix.Project

  def project do
    [
      app: :beamicom_host,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: []
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end

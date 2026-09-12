defmodule NxNes.MixProject do
  use Mix.Project

  def project do
    [
      app: :nx_nes,
      version: "0.1.0",
      elixir: "~> 1.20",
      deps: [{:beamicom, path: "../../beamicom"}, {:nx, "~> 0.13.1"}, {:exla, "~> 0.13.1"}]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end

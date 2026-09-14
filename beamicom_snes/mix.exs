defmodule BeamicomSNES.MixProject do
  use Mix.Project

  def project do
    [
      app: :beamicom_snes,
      version: "0.1.0",
      # CI currently uses the 1.20 release candidate; keep the lower bound
      # explicit while accepting the stable 1.x toolchain as it lands.
      elixir: ">= 1.20.0-rc.1 and < 2.0.0",
      start_permanent: Mix.env() == :prod,
      deps: []
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end
end

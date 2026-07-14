defmodule Beamicom.MixProject do
  use Mix.Project

  def project do
    [
      app: :beamicom,
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
      mod: {Beamicom.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  # The core emulator has no external dependencies. The Scenic local-verification
  # window lives in the sibling `beamicom_scenic` project, which depends on this.
  defp deps do
    []
  end
end

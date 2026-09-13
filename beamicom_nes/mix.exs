defmodule BeamicomNES.MixProject do
  use Mix.Project

  def project do
    [
      app: :beamicom_nes,
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
      mod: {Beamicom.NES.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  # Nx and EXLA are optional: native-only consumers do not fetch them. A host
  # that selects an Nx renderer includes both dependencies directly.
  defp deps do
    [
      {:beamicom_host, path: "../beamicom_host"},
      {:beamicom_ei, path: "../beamicom_ei"},
      {:nx, "~> 1.0", optional: true},
      {:exla, "~> 1.0", optional: true}
    ]
  end
end

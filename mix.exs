defmodule Peridiod.MixProject do
  use Mix.Project

  def project do
    [
      app: :peridiod,
      version: "1.1.0",
      elixir: "~> 1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        peridiod: [include_erts: System.get_env("PERIDIOD_INCLUDE_ERTS_DIR") || true]
      ]
    ]
  end

  def application, do: [extra_applications: [:crypto, :logger]]

  defp deps do
    [
      {:jason, "~> 1.0"},
      {:nerves_hub_cli, "~> 0.11.1", runtime: false},
      {:nerves_hub_link, "~> 1.2"},
      {:x509, "~> 0.8"}
    ]
  end
end

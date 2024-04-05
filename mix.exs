defmodule Peridiod.MixProject do
  use Mix.Project

  def project do
    [
      app: :peridiod,
      version: "2.5.0-dev",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        peridiod: [
          applications: [peridiod: :permanent],
          steps: [:assemble, :tar],
          include_erts: System.get_env("MIX_TARGET_INCLUDE_ERTS") || true
        ]
      ]
    ]
  end

  def application,
    do: [extra_applications: [:crypto, :logger, :inets], mod: {Peridiod.Application, []}]

  defp deps do
    [
      {:extty, "~> 0.2"},
      {:peridio_rat, github: "peridio/peridio-rat", branch: "main"},
      {:peridio_sdk, github: "peridio/peridio-elixir", branch: "main"},
      {:muontrap, "~> 1.3"},
      {:circuits_uart, "~> 1.5"},
      {:castore, "~> 1.0"},
      {:jason, "~> 1.0"},
      {:fwup, "~> 1.0"},
      {:hackney, "~> 1.10"},
      {:uboot_env, "~> 1.0"},
      {:slipstream, "~> 1.0 or ~> 0.8"},
      {:x509, "~> 0.8"}
    ]
  end
end

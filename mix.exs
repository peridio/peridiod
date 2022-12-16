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

  def application, do: [extra_applications: [:crypto, :logger, :inets], mod: {Peridiod.Application, []}]

  defp deps do
    [
      {:extty, "~> 0.2"},
      {:jason, "~> 1.0"},
      {:fwup, "~> 1.0"},
      {:hackney, "~> 1.10"},
      {:uboot_env, "~> 1.0"},
      {:slipstream, "~> 1.0 or ~> 0.8"},
      {:x509, "~> 0.8"}
    ]
  end
end

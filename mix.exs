defmodule Peridiod.MixProject do
  use Mix.Project

  @version File.read!("VERSION") |> String.trim()

  def project do
    [
      app: :peridiod,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      # aliases: [test: "test --no-start"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        peridiod: [
          applications: [peridiod: :permanent],
          include_executables_for: [:unix],
          steps: [:assemble, :tar],
          include_erts: System.get_env("MIX_TARGET_INCLUDE_ERTS") || true
        ]
      ]
    ]
  end

  def application,
    do: [extra_applications: [:crypto, :logger, :inets], mod: {Peridiod.Application, []}]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:gen_stage, "~> 1.0"},
      {:extty, "~> 0.2"},
      {:uuid, "~> 1.0"},
      {:telemetry, "~> 1.0"},
      {:peridiod_persistence, github: "peridio/peridiod-persistence", branch: "main"},
      {:peridio_rat, github: "peridio/peridio-rat", branch: "main"},
      {:peridio_sdk, github: "peridio/peridio-elixir", branch: "main"},
      {:erlexec, github: "peridio/erlexec"},
      {:circuits_uart, "~> 1.5"},
      {:castore, "~> 1.0"},
      {:jason, "~> 1.0"},
      {:hackney, "~> 1.10"},
      {:slipstream, "~> 1.0 or ~> 0.8"},
      {:x509, "~> 0.8"},
      {:plug, "~> 1.11", only: :test},
      {:plug_cowboy, "~> 2.5", only: :test}
    ]
  end
end

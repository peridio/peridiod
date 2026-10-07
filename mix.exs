defmodule Peridiod.MixProject do
  use Mix.Project

  @version File.read!("VERSION") |> String.trim()

  def project do
    [
      app: :peridiod,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      aliases: [test: "test --no-start"],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      hex: [ignore_advisories: ignore_advisories()],
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

  # Advisories with no available fix as of ENG-2677 (2026-09-23). cowlib 2.20.0 is
  # upstream's latest release; neither has a fixed version yet. Same class of finding
  # as peridio-proxy's ENG-2501.
  #
  # Safe to suppress here specifically: cowlib only enters this project transitively
  # via plug_cowboy, which is `only: :test` (see deps/0) — `mix deps.tree --only prod`
  # confirms cowboy/cowlib are absent from the production release entirely. That is
  # the whole justification. Both advisories are in header encoders
  # (cow_cookie:cookie/1 builds client-side Cookie request headers,
  # cow_http_struct_hd:escape_string/2 encodes structured headers), which do not need
  # a cowboy HTTP server, so they would apply if cowlib were ever part of a release.
  #
  # NOT self-cleaning: hex.audit only warns on a stale entry, it doesn't fail the
  # build, so this list can silently outlive the fix. Tracked in ENG-2677 to re-check
  # once cowlib ships a patched release.
  defp ignore_advisories do
    [
      "CVE-2026-43966",
      "CVE-2026-43969"
    ]
  end

  defp deps do
    [
      {:extty, "~> 0.2"},
      {:uuid, "~> 1.0"},
      {:telemetry, "~> 1.0"},
      {:peridiod_persistence, github: "peridio/peridiod-persistence", branch: "main"},
      {:peridio_rat, github: "peridio/peridio-rat", branch: "main"},
      {:peridio_sdk, github: "peridio/peridio-elixir", branch: "main"},
      {:peridio_net_mon, github: "peridio/peridio-net-mon", branch: "main"},
      {:erlexec, github: "peridio/erlexec"},
      {:circuits_uart, "~> 1.5"},
      {:castore, "~> 1.0"},
      {:jason, "~> 1.0"},
      {:slipstream, "~> 1.0 or ~> 0.8"},
      {:x509, "~> 0.8"},
      {:plug, "~> 1.11", only: :test},
      {:plug_cowboy, "~> 2.5", only: :test},
      {:req, "~> 0.6 and >= 0.6.1"}
    ]
  end
end

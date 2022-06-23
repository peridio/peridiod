defmodule PeridioAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :peridio_agent,
      version: "0.1.0",
      elixir: "~> 1.13",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:nerves_hub_link, "~> 1.2"},
      {:nerves_hub_cli, "~> 0.12"}
    ]
  end
end

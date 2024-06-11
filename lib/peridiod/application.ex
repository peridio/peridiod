defmodule Peridiod.Application do
  use Application

  alias Peridiod.{
    KV,
    Configurator,
    Connection,
    Socket,
    DistributionManager,
    ReleaseManager
  }

  def start(_type, _args) do
    application_config = Application.get_all_env(:peridiod)
    configurator_config = struct(Configurator.Config, application_config)

    children = [
      {KV, application_config},
      {Configurator, configurator_config},
      DistributionManager,
      ReleaseManager,
      Connection,
      Socket
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Peridiod.Supervisor)
  end
end

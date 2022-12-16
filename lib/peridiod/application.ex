defmodule Peridiod.Application do
  use Application

  alias Peridiod.{
    Configurator,
    Connection,
    Socket,
    UpdateManager,
    KV
  }

  def start(_type, _args) do
    application_config = Application.get_all_env(:peridiod)
    children = [
      {KV, application_config},
      Configurator,
      UpdateManager,
      Connection,
      Socket,
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Peridiod.Supervisor)
  end
end

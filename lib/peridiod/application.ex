defmodule Peridiod.Application do
  use Application

  alias Peridiod.{
    Cache,
    Connection,
    Socket,
    Distribution,
    Update,
    Binary
  }

  def start(_type, _args) do
    config = Peridiod.config()

    children = [
      {Cache, config},
      Binary.Installer.Supervisor,
      Binary.StreamDownloader.Supervisor,
      Binary.CacheDownloader.Supervisor,
      {Update.Server, config}
    ]

    children =
      case config.socket_enabled? do
        true ->
          children ++
            [
              Connection,
              {Socket, config},
              {Distribution.Server, config}
            ]

        false ->
          children
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: Peridiod.Supervisor)
  end
end

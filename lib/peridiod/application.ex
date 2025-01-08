defmodule Peridiod.Application do
  use Application

  alias Peridiod.{
    Cache,
    Connection,
    Socket,
    Distribution,
    Release,
    Binary
  }

  def start(_type, _args) do
    application_config = Application.get_all_env(:peridiod)
    config = struct(Peridiod.Config, application_config) |> Peridiod.Config.new()

    children = [
      {Cache, config},
      Binary.Installer.Supervisor,
      Binary.StreamDownloader.Supervisor,
      Binary.CacheDownloader.Supervisor,
      {Release.Server, config}
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

defmodule Peridiod.Cloud.Supervisor do
  use Supervisor

  alias Peridiod.{Cloud, Distribution}

  def start_link(config) do
    Supervisor.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl true
  def init(config) do
    peridio_net_mon_config = Application.get_all_env(:peridio_net_mon)

    children = [
      Cloud.Event,
      {Peridio.NetMon.Supervisor, peridio_net_mon_config},
      {Cloud.NetworkMonitor, config.network_monitor},
      {Cloud.Update, config},
      {Cloud, config}
    ]

    children =
      case config.socket_enabled? do
        true ->
          children ++
            [
              Cloud.Connection,
              {Cloud.Socket, config},
              {Distribution.Server, config}
            ]

        false ->
          children
      end

    children =
      case config.shadow_enabled do
        true -> children ++ [{Cloud.Shadow, config}]
        false -> children
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Peridiod.Application do
  use Application

  require Logger

  alias Peridiod.{
    Config,
    Cache,
    Cloud,
    Distribution,
    Update,
    Binary
  }

  def start(_type, _args) do
    config = Peridiod.config()
    configure_logger(config)

    peridio_net_mon_config = Application.get_all_env(:peridio_net_mon)

    children = [
      {Cache, config},
      {Peridio.NetMon.Supervisor, peridio_net_mon_config},
      {Cloud.NetworkMonitor, config.network_monitor},
      Binary.Installer.Supervisor,
      Binary.StreamDownloader.Supervisor,
      Binary.CacheDownloader.Supervisor,
      {Cloud, config},
      {Cloud.Update, config},
      {Update.Server, config}
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

    Supervisor.start_link(children, strategy: :one_for_one, name: Peridiod.Supervisor)
  end

  def configure_logger(%Config{cache_log_enabled: true} = config) do
    cache_dir = config.cache_dir
    log_dir = Path.join([cache_dir, "log"])
    log_file = Path.join(log_dir, "peridiod.log")
    :logger.remove_handler(:peridiod_cache_log)

    with :ok <- File.mkdir_p(log_dir),
         :ok <-
           :logger.add_handler(:peridiod_cache_log, :logger_std_h, %{
             config: %{
               file: ~c"#{log_file}",
               max_no_bytes: config.cache_log_max_bytes,
               max_no_files: config.cache_log_max_files,
               compress_on_rotate: config.cache_log_compress
             },
             formatter:
               {:logger_formatter,
                %{
                  template: [:time, " ", :level, " ", :msg, "\n"]
                }},
             level: config.cache_log_level
           }) do
      Logger.info("[Application Start] Cache log enabled at #{inspect(log_file)}")
    else
      error ->
        Logger.error(
          "[Application Start] Peridiod is unable to create cache log file at #{inspect(log_dir)} error #{inspect(error)}"
        )
    end
  end

  def configure_logger(_config) do
    Logger.info("[Application Start] Logger cache disabled")
  end
end

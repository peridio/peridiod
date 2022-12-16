import Config

config :peridiod,
  client: Peridiod.Client.Default,
  configurator: Peridiod.Configurator,
  kv_backend: {Peridiod.KVBackend.InMemory, contents: %{"peridio_disk_devpath" => "/dev/mmcblk1"}}


config :logger, level: :debug

import_config "#{Mix.env()}.exs"

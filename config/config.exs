import Config

config :peridiod,
  client: Peridiod.Client.Default,
  configurator: Peridiod.Configurator,
  kv_backend:
    {Peridiod.KVBackend.InMemory,
     contents: %{
       "peridio_disk_devpath" => "/dev/mmcblk1"
     }}

config :logger, level: :debug
config :peridio_rat, wireguard_client: Peridio.RAT.WireGuard.Default

import_config "#{Mix.env()}.exs"

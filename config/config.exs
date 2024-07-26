import Config

config :peridiod_persistence,
  kv_backend:
    {PeridiodPersistence.KVBackend.InMemory,
     contents: %{
       "peridio_disk_devpath" => "/dev/mmcblk1"
     }}

config :peridiod,
  client: Peridiod.Client.Default

config :peridio_rat, wireguard_client: Peridio.RAT.WireGuard.Default

import_config "#{Mix.env()}.exs"

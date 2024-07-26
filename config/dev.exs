import Config

config :logger, level: :debug

config :peridiod_persistence,
  kv_backend:
    {PeridiodPersistence.KVBackend.InMemory,
     contents: %{
       "peridio_disk_devpath" => "/dev/mmcblk1",
       "peridio_vsn_current" => System.get_env("PERIDIO_RELEASE_VERSION"),
       "peridio_rel_current" => System.get_env("PERIDIO_RELEASE_PRN")
     }}

config :peridiod,
  key_pair_source: "env",
  key_pair_config: %{
    "private_key" => "PERIDIO_PRIVATE_KEY",
    "certificate" => "PERIDIO_CERTIFICATE"
  },
  releases_enabled: false,
  socket_enabled?: false

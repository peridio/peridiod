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

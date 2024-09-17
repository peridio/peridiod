import Config

System.put_env("PERIDIO_CONFIG_FILE", "test/fixtures/peridio.json")

config :logger, level: :error
config :ex_unit, capture_log: true

config :peridiod_persistence,
  kv_backend:
    {PeridiodPersistence.KVBackend.InMemory,
     contents: %{"peridio_disk_devpath" => "/dev/mmcblk1"}}

config :peridiod,
  cache_dir: Path.expand("../test/workspace/cache", __DIR__),
  socket_enabled?: false

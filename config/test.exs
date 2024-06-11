import Config

System.put_env("PERIDIO_CONFIG_FILE", "test/fixtures/peridio.json")

config :logger, level: :error

config :peridiod,
  kv_backend:
    {Peridiod.KVBackend.InMemory, contents: %{"peridio_disk_devpath" => "/dev/mmcblk1"}},
  cache_dir: Path.expand("../test/workspace/cache", __DIR__),
  socket_enabled?: false

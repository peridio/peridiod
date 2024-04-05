import Config

System.put_env("PERIDIO_CONFIG_FILE", "test/fixtures/peridio.json")

config :peridiod,
  kv_backend: {Peridiod.KVBackend.InMemory, contents: %{"peridio_disk_devpath" => "/dev/mmcblk1"}}

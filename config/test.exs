import Config

config :peridiod,
  kv_backend: {Peridiod.KVBackend.InMemory, contents: %{"peridio_disk_devpath" => "/dev/mmcblk1"}}

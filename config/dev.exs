import Config

config :peridiod,
  kv_backend: {Peridiod.KVBackend.InMemory, contents: %{
    "peridio_disk_devpath" => "/dev/mmcblk1",
    "peridio_release_version" => System.get_env("PERIDIO_RELEASE_VERSION"),
    "peridio_release_prn" => System.get_env("PERIDIO_RELEASE_PRN")
  }},
  key_pair_config: %{"private_key" => "PERIDIO_PRIVATE_KEY", "certificate" => "PERIDIO_CERTIFICATE"},
  releases_enabled: true

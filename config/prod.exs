import Config

config :logger, level: :info

device_api_host = "device.cremini.peridio.com"

config :peridiod,
  device_api_host: device_api_host

config :erlexec,
  user: "root",
  limit_users: ["root"],
  kill_timeout: 5000

config :peridiod_persistence,
  kv_backend: PeridiodPersistence.KVBackend.UBootEnv

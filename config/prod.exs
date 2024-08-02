import Config

config :logger, level: :warning

config :erlexec,
  user: "root",
  limit_users: ["root"],
  kill_timeout: 5000

config :peridiod_persistence,
  kv_backend: PeridiodPersistence.KVBackend.UBootEnv

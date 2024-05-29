import Config

config :logger, level: :warning

config :peridiod,
  kv_backend: Peridiod.KVBackend.UBootEnv

config :erlexec,
  user: "root",
  limit_users: ["root"],
  kill_timeout: 5000

import Config

config :logger, level: :warning

config :peridiod,
  kv_backend: Peridiod.KVBackend.UBootEnv

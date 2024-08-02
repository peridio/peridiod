import Config

shell =
  System.find_executable("bash") || System.find_executable("zsh") || System.find_executable("sh")

System.put_env("SHELL", shell)

log_level =
  case System.get_env("PERIDIO_LOG_LEVEL") do
    "debug" -> :debug
    "warning" -> :warning
    "info" -> :info
    _ -> :error
  end

kv_backend =
  case System.get_env("PERIDIO_KV_BACKEND") do
    "filesystem" ->
      path = System.get_env("PERIDIO_KV_BACKEND_FILESYSTEM_PATH", "/var/peridiod")
      file = System.get_env("PERIDIO_KV_BACKEND_FILESYSTEM_FILE", "peridiod-state")
      {PeridiodPersistence.KVBackend.Filesystem, path: path, file: file}
    "ubootenv" -> PeridiodPersistence.KVBackend.UBootEnv
    _ -> PeridiodPersistence.KVBackend.UBootEnv
  end

config :peridiod_persistence,
  kv_backend: kv_backend

config :logger, level: log_level

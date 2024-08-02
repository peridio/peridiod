import Config

shell =
  System.find_executable("bash") || System.find_executable("zsh") || System.find_executable("sh")

System.put_env("SHELL", shell)

case System.get_env("PERIDIO_LOG_LEVEL") do
  nil -> :noop
  "debug" -> config :logger, level: :debug
  "warning" -> config :logger, level: :warning
  "info" -> config :logger, level: :info
  _ -> config :logger, level: :error
end

case System.get_env("PERIDIO_KV_BACKEND") do
  "filesystem" ->
    path = System.get_env("PERIDIO_KV_BACKEND_FILESYSTEM_PATH", "/var/peridiod")
    file = System.get_env("PERIDIO_KV_BACKEND_FILESYSTEM_FILE", "peridiod-state")

    config :peridiod_persistence,
      kv_backend: {PeridiodPersistence.KVBackend.Filesystem, path: path, file: file}

  "ubootenv" ->
    config :peridiod_persistence,
      kv_backend: PeridiodPersistence.KVBackend.UBootEnv

  _ ->
    :noop
end

defmodule Peridiod.Configurator.File do
  require Logger
  def config(%{"certificate_path" => cert_path, "private_key_path" => key_path}, nerves_config) do
    ssl_opts =
      nerves_config.ssl
      |> Keyword.put(:certfile, cert_path)
      |> Keyword.put(:keyfile, key_path)

    %{nerves_config | ssl: ssl_opts}
  end

  def config(_, nerves_config) do
    Logger.error("key_pair_source file requires certificate_path and private_key_path to be passed as key_pair_options")
    nerves_config
  end
end

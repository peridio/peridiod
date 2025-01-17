defmodule Peridiod.Config.File do
  require Logger

  import Peridiod.Utils, only: [private_key_from_pem_file: 1, public_key_from_pem_file: 1]

  def config(%{"certificate_path" => nil, "private_key_path" => nil}, base_config) do
    Logger.error("""
    [Config]
    Unable to set identity using file paths.
    Variables are unset. Check your peridiod configuration.
    """)

    base_config
  end

  def config(%{"certificate_path" => cert_path, "private_key_path" => key_path}, base_config) do
    ssl_opts =
      base_config.ssl
      |> Keyword.put(:certfile, cert_path)
      |> Keyword.put(:keyfile, key_path)

    %{
      base_config
      | ssl: ssl_opts,
        cache_private_key: load_private_key(key_path),
        cache_public_key: load_public_key(cert_path)
    }
  end

  def config(_, base_config) do
    Logger.error(
      "[Config] key_pair_source file requires certificate_path and private_key_path to be passed as key_pair_options"
    )

    base_config
  end

  def load_private_key(pem_file) do
    case private_key_from_pem_file(pem_file) do
      {:ok, private_key} ->
        private_key

      {:error, error} ->
        Logger.warning("[Config] Unable to load cache encryption private key: #{inspect(error)}")
        nil
    end
  end

  def load_public_key(pem_file) do
    case public_key_from_pem_file(pem_file) do
      {:ok, public_key} ->
        public_key

      {:error, error} ->
        Logger.warning("[Config] Unable to load cache encryption public keyy: #{inspect(error)}")
        nil
    end
  end
end

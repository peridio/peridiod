defmodule Peridiod.Config.File do
  require Logger

  def config(%{"certificate_path" => nil, "private_key_path" => nil}, base_config) do
    Logger.error("""
    [Config]
    Unable to set identity using file paths.
    Variables are unset. Check your peridiod configuration.
    """)

    base_config
  end

  def config(
        %{"certificate_path" => cert_path, "private_key_path" => key_path},
        base_config
      )
      when is_binary(cert_path) and is_binary(key_path) do
    cert =
      Peridiod.Certificate.certificate_from_pem_file!(cert_path,
        source: "file",
        path: cert_path
      )

    key =
      Peridiod.Certificate.private_key_from_pem_file!(key_path,
        source: "file",
        path: key_path
      )

    ssl_opts =
      base_config.ssl
      |> Keyword.put(:certfile, cert_path)
      |> Keyword.put(:keyfile, key_path)

    %{
      base_config
      | ssl: ssl_opts,
        cache_private_key: key,
        cache_public_key: X509.Certificate.public_key(cert)
    }
  end

  def config(_, base_config) do
    Logger.error(
      "[Config] key_pair_source file requires certificate_path and private_key_path to be passed as key_pair_options"
    )

    base_config
  end
end

defmodule Peridiod.Config.Env do
  import Peridiod.Utils, only: [try_base64_decode: 1, pem_certificate_trim: 1]

  require Logger

  def config(%{"private_key" => nil, "certificate" => nil}, base_config) do
    Logger.error("""
    [Config]
    Unable to set identity using Environmenmt variables.
    Variables are unset. Check your peridiod configuration.
    """)

    base_config
  end

  def config(
        %{"private_key" => key_env_var, "certificate" => cert_env_var},
        base_config
      )
      when is_binary(key_env_var) and is_binary(cert_env_var) do
    with {:ok, key_raw} <- System.fetch_env(key_env_var),
         {:ok, cert_raw} <- System.fetch_env(cert_env_var) do
      key_pem = try_base64_decode(key_raw)
      cert_pem = try_base64_decode(cert_raw) |> pem_certificate_trim()
      set_ssl_opts(cert_pem, key_pem, cert_env_var, key_env_var, base_config)
    else
      _e ->
        Logger.error("""
        [Config]
        Unable to fetch the key / certificate from the environment.
          key:  #{key_env_var}
          cert: #{cert_env_var}
        """)

        base_config
    end
  end

  def config(_, base_config) do
    Logger.error(
      "[Config] key_pair_source env requires private_key and certificate to be passed as key_pair_options"
    )

    base_config
  end

  defp set_ssl_opts(cert_pem, key_pem, cert_env_var, key_env_var, base_config) do
    cert =
      Peridiod.Certificate.certificate_from_pem!(cert_pem,
        source: "env",
        path: cert_env_var
      )

    key =
      Peridiod.Certificate.private_key_from_pem!(key_pem,
        source: "env",
        path: key_env_var
      )

    ssl_opts =
      base_config.ssl
      |> Keyword.put(:cert, X509.Certificate.to_der(cert))
      |> Keyword.put(:key, {:ECPrivateKey, X509.PrivateKey.to_der(key)})

    %{
      base_config
      | ssl: ssl_opts,
        cache_private_key: key,
        cache_public_key: X509.Certificate.public_key(cert)
    }
  end
end

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

  def config(%{"private_key" => key, "certificate" => cert}, base_config) do
    with {:ok, key} <- System.fetch_env(key),
         {:ok, cert} <- System.fetch_env(cert) do
      key_pem = try_base64_decode(key)
      cert_pem = try_base64_decode(cert) |> pem_certificate_trim()
      set_ssl_opts(cert_pem, key_pem, base_config)
    else
      _e ->
        Logger.error("""
        [Config]
        Unset error fetching the key / certificate from the environment")
          key:  #{key}
          cert: #{cert}
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

  defp set_ssl_opts(cert_pem, key_pem, base_config) do
    ssl_opts =
      base_config.ssl
      |> Keyword.put(:cert, cert_pem_to_der(cert_pem))
      |> Keyword.put(:key, {:ECPrivateKey, key_pem_to_der(key_pem)})

    %{
      base_config
      | ssl: ssl_opts,
        cache_private_key: load_private_key(key_pem),
        cache_public_key: load_public_key(cert_pem)
    }
  end

  defp cert_pem_to_der(cert_pem) do
    case X509.Certificate.from_pem(cert_pem) do
      {:ok, cert_erl} ->
        cert_erl |> X509.Certificate.to_der()

      {error, _} ->
        Logger.error(
          "[Config] An error occurred while reading the certificate from env:\n#{error}"
        )

        ""
    end
  end

  defp key_pem_to_der(key_pem) do
    case X509.PrivateKey.from_pem(key_pem) do
      {:ok, key_erl} ->
        key_erl |> X509.PrivateKey.to_der()

      {error, _} ->
        Logger.error(
          "[Config] An error occurred while reading the private key from env:\n#{error}"
        )

        ""
    end
  end

  def load_private_key(private_pem) do
    case X509.PrivateKey.from_pem(private_pem) do
      {:ok, private_key} ->
        private_key

      {:error, error} ->
        Logger.warning("[Config] Unable to load cache encryption private key: #{inspect(error)}")
        nil
    end
  end

  def load_public_key(certificate_pem) do
    case X509.Certificate.from_pem(certificate_pem) do
      {:ok, certificate} ->
        X509.Certificate.public_key(certificate)

      {:error, error} ->
        Logger.warning("[Config] Unable to load cache encryption public keyy: #{inspect(error)}")
        nil
    end
  end
end

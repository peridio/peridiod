defmodule Peridiod.Configurator.Env do
  require Logger

  import Peridiod.Utils, only: [try_base64_decode: 1]

  def config(%{"private_key" => nil, "certificate" => nil}, base_config) do
    Logger.error("""
    Unable to set identity using Environmenmt variables.
    Variables are unset. Check your peridiod configuration.
    """)

    base_config
  end

  def config(%{"private_key" => key, "certificate" => cert}, base_config) do
    with {:ok, key} <- System.fetch_env(key),
         {:ok, cert} <- System.fetch_env(cert) do
      key_pem = try_base64_decode(key)
      cert_pem = try_base64_decode(cert)
      set_ssl_opts(cert_pem, key_pem, base_config)
    else
      _e ->
        Logger.error("""
        Unset error fetching the key / certificate from the environment")
          key:  #{key}
          cert: #{cert}
        """)
    end
  end

  def config(_, base_config) do
    Logger.error(
      "key_pair_source env requires private_key and certificate to be passed as key_pair_options"
    )

    base_config
  end

  defp set_ssl_opts(cert_pem, key_pem, base_config) do
    ssl_opts =
      base_config.ssl
      |> Keyword.put(:cert, cert_pem_to_der(cert_pem))
      |> Keyword.put(:key, {:ECPrivateKey, key_pem_to_der(key_pem)})

    %{base_config | ssl: ssl_opts}
  end

  defp cert_pem_to_der(cert_pem) do
    case X509.Certificate.from_pem(cert_pem) do
      {:ok, cert_erl} ->
        cert_erl |> X509.Certificate.to_der()

      {error, _} ->
        Logger.error("An error occurred while reading the certificate from env:\n#{error}")
        ""
    end
  end

  defp key_pem_to_der(key_pem) do
    case X509.PrivateKey.from_pem(key_pem) do
      {:ok, key_erl} ->
        key_erl |> X509.PrivateKey.to_der()

      {error, _} ->
        Logger.error("An error occurred while reading the private key from env:\n#{error}")
        ""
    end
  end
end

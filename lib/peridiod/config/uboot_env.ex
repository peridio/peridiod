defmodule Peridiod.Config.UBootEnv do
  require Logger

  alias PeridiodPersistence.KV
  import Peridiod.Utils, only: [try_base64_decode: 1, pem_certificate_trim: 1]

  def config(%{"private_key" => key, "certificate" => cert}, base_config) do
    key_pem = KV.get(key) |> try_base64_decode()
    cert_pem = KV.get(cert) |> try_base64_decode() |> pem_certificate_trim()

    cert = cert_from_pem(cert_pem)
    cert_der = X509.Certificate.to_der(cert)

    key = key_from_pem(key_pem)
    key_der = X509.PrivateKey.to_der(key)

    ssl_opts =
      base_config.ssl
      |> Keyword.put(:cert, cert_der)
      |> Keyword.put(:key, {:ECPrivateKey, key_der})

    %{
      base_config
      | ssl: ssl_opts,
        cache_private_key: key,
        cache_public_key: X509.Certificate.public_key(cert)
    }
  end

  def config(_, base_config) do
    Logger.error(
      "key_pair_source uboot-env requires private_key and certificate to be passed as key_pair_options"
    )

    base_config
  end

  defp cert_from_pem(cert_pem) do
    case X509.Certificate.from_pem(cert_pem) do
      {:ok, cert} ->
        cert

      {error, _} ->
        Logger.error("An error occurred while reading the certificate from uboot_env:\n#{error}")
        ""
    end
  end

  defp key_from_pem(key_pem) do
    case X509.PrivateKey.from_pem(key_pem) do
      {:ok, key} ->
        key

      {error, _} ->
        Logger.error("An error occurred while reading the private key from uboot_env:\n#{error}")
        ""
    end
  end
end

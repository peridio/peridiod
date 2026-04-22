defmodule Peridiod.Config.UBootEnv do
  require Logger

  alias PeridiodPersistence.KV
  import Peridiod.Utils, only: [try_base64_decode: 1, pem_certificate_trim: 1]

  def config(
        %{"private_key" => key_kv_key, "certificate" => cert_kv_key},
        base_config
      )
      when is_binary(key_kv_key) and is_binary(cert_kv_key) do
    key_pem =
      case KV.get(key_kv_key) do
        nil ->
          raise Peridiod.Certificate.ParseError,
            field: :private_key,
            source: "uboot-env",
            path: key_kv_key,
            reason: :not_found

        raw ->
          try_base64_decode(raw)
      end

    cert_pem =
      case KV.get(cert_kv_key) do
        nil ->
          raise Peridiod.Certificate.ParseError,
            field: :certificate,
            source: "uboot-env",
            path: cert_kv_key,
            reason: :not_found

        raw ->
          try_base64_decode(raw) |> pem_certificate_trim()
      end

    cert =
      Peridiod.Certificate.certificate_from_pem!(cert_pem,
        source: "uboot-env",
        path: cert_kv_key
      )

    key =
      Peridiod.Certificate.private_key_from_pem!(key_pem,
        source: "uboot-env",
        path: key_kv_key
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

  def config(_, base_config) do
    Logger.error(
      "[Config] key_pair_source uboot-env requires private_key and certificate to be passed as key_pair_options"
    )

    base_config
  end
end

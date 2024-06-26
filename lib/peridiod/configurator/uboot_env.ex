defmodule Peridiod.Configurator.UBootEnv do
  require Logger

  import Peridiod.Utils, only: [try_base64_decode: 1]

  def config(%{"private_key" => key, "certificate" => cert}, base_config) do
    key_pem = Peridiod.KV.get(key) |> try_base64_decode()
    cert_pem = Peridiod.KV.get(cert) |> try_base64_decode()

    ssl_opts =
      base_config.ssl
      |> Keyword.put(:cert, cert_pem_to_der(cert_pem))
      |> Keyword.put(:key, {:ECPrivateKey, key_pem_to_der(key_pem)})

    %{base_config | ssl: ssl_opts}
  end

  def config(_, base_config) do
    Logger.error(
      "key_pair_source uboot-env requires private_key and certificate to be passed as key_pair_options"
    )

    base_config
  end

  defp cert_pem_to_der(cert_pem) do
    case X509.Certificate.from_pem(cert_pem) do
      {:ok, cert_erl} ->
        cert_erl |> X509.Certificate.to_der()

      {error, _} ->
        Logger.error("An error occurred while reading the certificate from uboot_env:\n#{error}")
        ""
    end
  end

  defp key_pem_to_der(key_pem) do
    case X509.PrivateKey.from_pem(key_pem) do
      {:ok, key_erl} ->
        key_erl |> X509.PrivateKey.to_der()

      {error, _} ->
        Logger.error("An error occurred while reading the private key from uboot_env:\n#{error}")
        ""
    end
  end
end

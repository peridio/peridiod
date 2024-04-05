defmodule Peridiod.Configurator.Env do
  require Logger

  def config(%{"private_key" => key, "certificate" => cert}, base_config) do
    key_pem = System.fetch_env!(key)
    cert_pem = System.fetch_env!(cert)

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
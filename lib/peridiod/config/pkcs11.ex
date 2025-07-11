defmodule Peridiod.Config.PKCS11 do
  require Logger

  def config(%{"key_id" => key_id} = key_pair_config, base_config) do
    pkcs11_path = key_pair_config["pkcs11_path"] || pkcs11_path()

    {:ok, engine} = :crypto.ensure_engine_loaded("pkcs11", pkcs11_path)

    key = %{
      algorithm: :ecdsa,
      engine: engine,
      key_id: key_id
    }

    ssl_opts =
      base_config.ssl
      |> Keyword.put(:key, key)

    add_certificate(%{base_config | ssl: ssl_opts, cache_private_key: key}, key_pair_config)
  end

  def config(_, base_config) do
    Logger.error(
      "[Config] key_pair_source pkcs11 requires key_id to be passed as key_pair_options"
    )

    base_config
  end

  defp add_certificate(base_config, %{"cert_id" => cert_id}) do
    cert =
      case System.cmd("p11tool", ["--export-stapled", cert_id]) do
        {cert_pem, 0} ->
          cert_pem |> X509.Certificate.from_pem!()

        {error, _} ->
          Logger.error(
            "[Config] An error occurred while reading the certificate from pkcs11:\n#{error}"
          )

          ""
      end

    cert_der = X509.Certificate.to_der(cert)

    ssl_opts =
      base_config.ssl
      |> Keyword.put(:cert, cert_der)

    %{
      base_config
      | ssl: ssl_opts,
        cache_public_key: X509.Certificate.public_key(cert)
    }
  end


  defp add_certificate(base_config, %{"certificate_path" => certificate_path}) do
    ssl_opts =
      base_config.ssl
      |> Keyword.put(:certfile, certificate_path)

    %{
      base_config
      | ssl: ssl_opts,
        cache_public_key: Peridiod.Config.File.load_public_key(certificate_path)
    }
  end

  defp add_certificate(base_config, _) do
    Logger.error(
      "[Config] key_pair_source pkcs11 requires cert_id or certificate_path to be passed as key_pair_options"
    )

    base_config
  end

  defp pkcs11_path() do
    [
      "/usr/lib/engines-1.1/libpkcs11.so",
      "/usr/lib/engines/libpkcs11.so",
      "/usr/lib/engines-3/libpkcs11.so",
      "/usr/lib64/engines-3/libpkcs11.so"
    ]
    |> Enum.find(&File.exists?/1)
  end
end


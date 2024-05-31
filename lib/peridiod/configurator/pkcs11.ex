defmodule Peridiod.Configurator.PKCS11 do
  require Logger

  def config(%{"key_id" => key_id, "cert_id" => cert_id} = key_pair_config, base_config) do
    pkcs11_path = key_pair_config["pkcs11_path"] || pkcs11_path()

    {:ok, engine} = :crypto.ensure_engine_loaded("pkcs11", pkcs11_path)

    key = %{
      algorithm: :ecdsa,
      engine: engine,
      key_id: key_id
    }

    cert =
      case System.cmd("p11tool", ["--export-stapled", cert_id]) do
        {cert_pem, 0} ->
          cert_pem |> X509.Certificate.from_pem!() |> X509.Certificate.to_der()

        {error, _} ->
          Logger.error("An error occurred while reading the certificate from pkcs11:\n#{error}")
          ""
      end

    ssl_opts =
      base_config.ssl
      |> Keyword.put(:cert, cert)
      |> Keyword.put(:key, key)

    %{base_config | ssl: ssl_opts}
  end

  def config(_, base_config) do
    Logger.error(
      "key_pair_source pkcsll requires key_id and cert_id to be passed as key_pair_options"
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

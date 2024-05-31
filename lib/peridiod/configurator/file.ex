defmodule Peridiod.Configurator.File do
  require Logger

  def config(%{"certificate_path" => nil, "private_key_path" => nil}, base_config) do
    Logger.error("""
    Unable to set identity using file paths.
    Variables are unset. Check your peridiod configuration.
    """)

    base_config
  end

  def config(%{"certificate_path" => cert_path, "private_key_path" => key_path}, base_config) do
    ssl_opts =
      base_config.ssl
      |> Keyword.put(:certfile, cert_path)
      |> Keyword.put(:keyfile, key_path)

    %{base_config | ssl: ssl_opts}
  end

  def config(_, base_config) do
    Logger.error(
      "key_pair_source file requires certificate_path and private_key_path to be passed as key_pair_options"
    )

    base_config
  end
end

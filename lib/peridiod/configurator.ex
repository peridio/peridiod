defmodule Peridiod.Configurator do
  alias __MODULE__
  alias Peridiod.Config

  require Logger

  @behaviour NervesHubLink.Configurator

  @impl NervesHubLink.Configurator
  def build(base_nerves_config) do
    nerves_config(Config.resolve_config(), base_nerves_config)
  end

  defp nerves_config(peridio_config, base_nerves_config) do
    verify =
      case peridio_config.device_api.verify do
        true -> :verify_peer
        false -> :verify_none
      end
    config =
    %{
      base_nerves_config
      | device_api_host: peridio_config.device_api.url,
        device_api_sni: peridio_config.device_api.url,
        fwup_devpath: peridio_config.fwup.devpath,
        fwup_public_keys: peridio_config.fwup.public_keys,
        socket: [url: "wss://#{peridio_config.device_api.url}:443/socket/websocket"],
        remote_iex: peridio_config.remote_shell,
        ssl: [
          server_name_indication: to_charlist(peridio_config.device_api.url),
          verify: verify,
          cacertfile: peridio_config.device_api.certificate_path,
        ]
    }

    case peridio_config.node.key_pair_source do
      "file" ->
        Configurator.File.config(peridio_config.node.key_pair_config, config)
      "pkcs11" ->
        Configurator.PKCS11.config(peridio_config.node.key_pair_config, config)
      type ->
        Logger.error("Unknown key pair type: #{type}")
    end
  end
end

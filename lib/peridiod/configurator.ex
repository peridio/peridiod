defmodule Peridiod.Configurator do
  alias Peridiod.Config

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
          certfile: peridio_config.node.certificate_path,
          keyfile: peridio_config.node.private_key_path
        ]
    }
  end
end

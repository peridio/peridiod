defmodule Peridiod.Tunnel do
  # Cloud -> Device: Request to open a tunnel
  # Device -> Cloud: Response public key, available cidrs, and available ports
  # Cloud -> Device: Response interface / peer information
  alias Peridio.RAT.Network

  def configure_request(config, interface, tunnel_prn) do
    adapter = {Tesla.Adapter.Mint, transport_opts: config[:ssl]}

    client =
      PeridioSDK.Client.new(
        device_api_host: config[:device_api_host],
        adapter: adapter,
        release_prn: "",
        release_version: ""
      )

    tunnel_opts = %{
      cidr_blocks: Network.available_cidrs(),
      port_ranges: Network.available_ports(),
      device_proxy_port: interface.port,
      device_tunnel_port: 22,
      device_public_key: interface.public_key
    }

    PeridioSDK.DeviceAPI.Tunnels.configure(client, tunnel_prn, tunnel_opts)
  end

  defimpl Jason.Encoder, for: Range do
    def encode(range, opts) do
      first = range.first
      last = range.last

      range_string = "#{first}-#{last}"

      Jason.Encode.string(range_string, opts)
    end
  end

  defimpl Jason.Encoder, for: Peridio.RAT.Network.CIDR do
    def encode(cidr, opts) do
      Jason.Encode.string(Peridio.RAT.Network.CIDR.to_string(cidr), opts)
    end
  end
end

defmodule Peridiod.Tunnel do
  # Cloud -> Device: Request to open a tunnel
  # Device -> Cloud: Response public key, available cidrs, and available ports
  # Cloud -> Device: Response interface / peer information
  require Logger
  alias Peridio.RAT.Network

  def create(client, tunnel_prn, dport, rat_config) do
    opts =
      [
        dport: dport,
        ipv4_cidrs: rat_config.ipv4_cidrs,
        port_range: rat_config.port_range
      ]

    interface =
      Peridio.RAT.WireGuard.generate_key_pair()
      |> Peridio.RAT.WireGuard.Interface.new()

    case Peridiod.Tunnel.configure_request(client, opts, interface, tunnel_prn) do
      {:ok, resp} ->
        {:ok, expires_at, _} = DateTime.from_iso8601(resp.body["data"]["expires_at"])

        peer = %Peridio.RAT.WireGuard.Peer{
          ip_address: resp.body["data"]["server_proxy_ip_address"],
          endpoint: resp.body["data"]["server_tunnel_ip_address"],
          port: resp.body["data"]["server_proxy_port"],
          public_key: resp.body["data"]["server_public_key"],
          persistent_keepalive: rat_config.persistent_keepalive
        }

        ip_address =
          resp.body["data"]["device_proxy_ip_address"]
          |> String.split(".")
          |> Enum.map(&String.to_integer/1)
          |> List.to_tuple()
          |> Peridio.RAT.Network.IP.new()

        interface = Map.put(interface, :ip_address, ip_address)
        args = [interface.id, opts[:dport]] |> Enum.join(" ")

        hooks = """
        PreUp = #{rat_config.hooks.pre_up} #{args}
        PostUp = #{rat_config.hooks.post_up} #{args}
        PreDown = #{rat_config.hooks.pre_down} #{args}
        PostDown = #{rat_config.hooks.post_down} #{args}
        """

        Peridio.RAT.open_tunnel(tunnel_prn, interface, peer, expires_at: expires_at, hooks: hooks)

      error ->
        Logger.error("Remote Tunnel Error #{inspect(error)}")
    end
  end

  def configure_request(client, opts, interface, tunnel_prn) do
    tunnel_opts = %{
      cidr_blocks: Network.available_cidrs(opts[:ipv4_cidrs]),
      port_ranges: Network.available_ports(opts[:port_range]),
      device_proxy_port: interface.port,
      device_tunnel_port: opts[:dport],
      device_public_key: interface.public_key
    }

    PeridioSDK.DeviceAPI.Tunnels.configure(client, tunnel_prn, tunnel_opts)
  end

  def close_request(client, tunnel_prn, reason) do
    PeridioSDK.DeviceAPI.Tunnels.update(client, tunnel_prn, %{state: "closed", close_reason: reason})
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

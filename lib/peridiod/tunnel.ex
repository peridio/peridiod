defmodule Peridiod.Tunnel do
  # Cloud -> Device: Request to open a tunnel
  # Device -> Cloud: Response public key, available cidrs, and available ports
  # Cloud -> Device: Response interface / peer information
  require Logger

  alias Peridio.RAT
  alias Peridio.RAT.{Network, WireGuard}

  def create(client, tunnel_prn, dport, rat_config) do
    Logger.debug("Tunnel Create #{tunnel_prn}")

    opts =
      [
        dport: dport,
        ipv4_cidrs: rat_config.ipv4_cidrs,
        port_range: rat_config.port_range
      ]

    interface =
      WireGuard.generate_key_pair()
      |> WireGuard.Interface.new()

    case configure_request(client, opts, interface, tunnel_prn) do
      {:ok, %{body: %{"data" => tunnel_data}}} ->
        configure_response(client, tunnel_data, interface, rat_config, opts)

      error ->
        Logger.error("Remote Tunnel Error #{inspect(error)}")
    end
  end

  def close(tunnel_prn, reason \\ :normal) do
    RAT.close_tunnel(tunnel_prn, reason)
  end

  @doc """
  Synchronize with the server
  """
  def synchronize(_client, %{enabled: false}) do
    Logger.info("Remote Access Tunnels disabled skipping sync")
    :ok
  end

  def synchronize(client, rat_config) do
    local_tunnels = RAT.list_tunnels()
    local_tunnel_prns = Enum.map(local_tunnels, &elem(&1, 0))

    case PeridioSDK.DeviceAPI.Tunnels.list(client) do
      {:ok, %{body: %{"tunnels" => []}}} ->
        Logger.debug("No Tunnels")
        Enum.each(local_tunnels, &close(elem(&1, 0)))
        :ok

      {:ok, %{body: %{"tunnels" => tunnels}}} ->
        Logger.debug("Server Tunnels: #{inspect(tunnels)}")
        unknown_tunnels = Enum.reject(tunnels, &(&1["prn"] in local_tunnel_prns))
        Logger.debug("Unknown Tunnels: #{inspect(unknown_tunnels)}")

        {unknown_requested, unknown_other} =
          Enum.split_with(unknown_tunnels, &(&1["state"] == "requested"))

        # Continue setting up any tunnels that are requested
        Enum.each(
          unknown_requested,
          &create(client, &1["prn"], &1["device_tunnel_port"], rat_config)
        )

        Logger.debug("Unknown Requested: #{inspect(unknown_requested)}")

        interface_confs =
          WireGuard.list_interfaces(data_dir: rat_config.data_dir)

        unknown_open = Enum.filter(unknown_other, &(&1["state"] == "open"))
        Logger.debug("Unknown Open: #{inspect(unknown_open)}")

        # Handle tunnels that are open
        Enum.each(unknown_open, fn tunnel_data ->
          conf =
            Enum.find(interface_confs, fn interface ->
              [{"TunnelID", tunnel_id}] =
                WireGuard.QuickConfig.get_in_extra(interface, ["Peridio", "TunnelID"])

              String.equivalent?(tunnel_id, tunnel_data["prn"])
            end)

          case conf do
            # Server lists tunnel as open, but the config is missing locally. No way to recover, close the tunnel
            nil ->
              Logger.debug("Close Open: #{inspect(tunnel_data["prn"])}")
              close_request(client, tunnel_data["prn"], "device_tunnel_abnormal_down")

            # Server lists tunnel as open, create a new tunnel process and resume
            conf ->
              opts = [
                dport: tunnel_data["device_tunnel_port"],
                ipv4_cidrs: rat_config.ipv4_cidrs,
                port_range: rat_config.port_range
              ]

              configure_response(client, tunnel_data, conf.interface, rat_config, opts)
          end
        end)

        # Clean up any unknown remaining local interfaces and confs
        expected_prns = Enum.map(tunnels, & &1["prn"])

        expected_interfaces =
          WireGuard.list_interfaces(data_dir: rat_config.data_dir)
          |> Enum.reduce([], fn conf, acc ->
            [{"TunnelID", tunnel_id}] =
              WireGuard.QuickConfig.get_in_extra(conf, ["Peridio", "TunnelID"])

            if tunnel_id in expected_prns do
              [conf.interface.id | acc]
            else
              acc
            end
          end)

        tunnel_interfaces = Enum.map(RAT.list_tunnels(), &elem(&1, 2).id)
        network_interfaces = WireGuard.Interface.network_interfaces()

        conf_interfaces =
          Enum.map(
            WireGuard.list_interfaces(data_dir: rat_config.data_dir),
            & &1.interface.id
          )

        local_interfaces = Enum.uniq(network_interfaces ++ conf_interfaces ++ tunnel_interfaces)

        cleanup_interfaces =
          Enum.reject(local_interfaces, &(&1 in expected_interfaces))

        Enum.each(
          cleanup_interfaces,
          &WireGuard.teardown_interface(&1, data_dir: rat_config.data_dir)
        )

      error ->
        Logger.error("Tunnel synchronize error: #{inspect(error)}")
        error
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
    PeridioSDK.DeviceAPI.Tunnels.update(client, tunnel_prn, %{
      state: "closed",
      close_reason: reason
    })
  end

  defp configure_response(client, tunnel_data, interface, rat_config, opts) do
    tunnel_prn = tunnel_data["prn"]
    {:ok, expires_at, _} = DateTime.from_iso8601(tunnel_data["expires_at"])

    peer = %WireGuard.Peer{
      ip_address: tunnel_data["server_proxy_ip_address"],
      endpoint: tunnel_data["server_tunnel_ip_address"],
      port: tunnel_data["server_proxy_port"],
      public_key: tunnel_data["server_public_key"],
      persistent_keepalive: rat_config.persistent_keepalive
    }

    ip_address =
      tunnel_data["device_proxy_ip_address"]
      |> String.split(".")
      |> Enum.map(&String.to_integer/1)
      |> List.to_tuple()
      |> Network.IP.new()

    interface = Map.put(interface, :ip_address, ip_address)
    args = [interface.id, opts[:dport]] |> Enum.join(" ")

    hooks = [
      {"PreUp", "#{rat_config.hooks.pre_up} #{args}"},
      {"PostUp", "#{rat_config.hooks.post_up} #{args}"},
      {"PreDown", "#{rat_config.hooks.pre_down} #{args}"},
      {"PostDown", "#{rat_config.hooks.post_down} #{args}"}
    ]

    on_exit = fn reason ->
      Peridiod.Tunnel.close_request(client, tunnel_prn, reason)
    end

    RAT.open_tunnel(tunnel_prn, interface, peer,
      expires_at: expires_at,
      hooks: hooks,
      on_exit: on_exit,
      data_dir: rat_config.data_dir
    )
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

defmodule Peridiod.Cloud.Tunnel do
  # Cloud -> Device: Request to open a tunnel
  # Device -> Cloud: Response public key, available cidrs, and available ports
  # Cloud -> Device: Response interface / peer information
  require Logger

  alias Peridiod.Cloud
  alias Peridio.RAT
  alias Peridio.RAT.{Network, WireGuard}

  @routing_table 555

  def create(client, tunnel_prn, dport, rat_config) do
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
        error
    end
  end

  def close(tunnel_prn, reason \\ :normal) do
    RAT.close_tunnel(tunnel_prn, reason)
  end

  @doc """
  Synchronize with the server
  """
  def synchronize(_client, %{enabled: false}) do
    Logger.info("[Remote Access Tunnels] Disabled skipping sync")
    :ok
  end

  def synchronize(client, rat_config) do
    local_tunnels = RAT.list_tunnels()
    local_tunnel_prns = Enum.map(local_tunnels, &elem(&1, 0))

    case PeridioSDK.DeviceAPI.Tunnels.list(client) do
      {:ok, %{body: %{"tunnels" => []}}} ->
        Enum.each(local_tunnels, &close(elem(&1, 0)))
        :ok

      {:ok, %{body: %{"tunnels" => tunnels}}} ->
        unknown_tunnels = Enum.reject(tunnels, &(&1["prn"] in local_tunnel_prns))

        {unknown_requested, unknown_other} =
          Enum.split_with(unknown_tunnels, &(&1["state"] == "requested"))

        # Continue setting up any tunnels that are requested
        Enum.each(
          unknown_requested,
          &create(client, &1["prn"], &1["device_tunnel_port"], rat_config)
        )

        interface_confs =
          WireGuard.list_interfaces(data_dir: rat_config.data_dir)

        unknown_open = Enum.filter(unknown_other, &(&1["state"] == "open"))

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
              Logger.debug(
                "[Remote Access Tunnels] Closing open tunnel missing local config: #{inspect(tunnel_data["prn"])}"
              )

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
        Logger.error("[Remote Access Tunnels] Synchronize error: #{inspect(error)}")
        error
    end
  end

  def update_bind_interface(ifname, rat_config) do
    interface_confs =
      WireGuard.list_interfaces(data_dir: rat_config.data_dir)

    table = if ifname, do: :off, else: :auto

    interface_confs
    |> Enum.each(&WireGuard.teardown_interface(&1.interface.id, data_dir: rat_config.data_dir))

    interface_confs =
      interface_confs
      |> Enum.map(&update_in(&1, [Access.key(:interface), Access.key(:table)], fn _ -> table end))
      |> Enum.map(fn quick_config ->
        [{_, dport}] = WireGuard.QuickConfig.get_in_extra(quick_config, ["Peridio", "DPort"])

        hooks =
          hooks(
            rat_config,
            quick_config.interface,
            quick_config.peer,
            dport,
            ifname
          )

        extra = Enum.reject(quick_config.extra, &(elem(&1, 0) == "Interface"))
        %{quick_config | extra: [{"Interface", hooks} | extra]}
      end)

    interface_confs
    |> Enum.each(
      &WireGuard.configure_wireguard(&1.interface, &1.peer,
        extra: &1.extra,
        data_dir: rat_config.data_dir
      )
    )

    interface_confs
    |> Enum.each(&WireGuard.bring_up_interface(&1.interface.id, data_dir: rat_config.data_dir))
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

    wan_ifname = Cloud.NetworkMonitor.get_bound_interface()
    table = if wan_ifname, do: :off, else: :auto

    interface =
      interface
      |> Map.put(:ip_address, ip_address)
      |> Map.put(:table, table)

    hooks = hooks(rat_config, interface, peer, opts[:dport], wan_ifname)

    on_exit = fn reason ->
      Peridiod.Cloud.Tunnel.close_request(client, tunnel_prn, reason)
    end

    RAT.open_tunnel(tunnel_prn, interface, peer,
      expires_at: expires_at,
      hooks: hooks,
      on_exit: on_exit,
      data_dir: rat_config.data_dir,
      extra: [{"Peridio", [{"DPort", opts[:dport]}]}]
    )
  end

  defp hooks(rat_config, interface, peer, dport, wan_ifname) do
    routing_table = rat_config[:routing_table] || @routing_table

    args =
      [
        interface.id,
        dport,
        interface.ip_address,
        "#{peer.ip_address}/32",
        wan_ifname,
        peer.endpoint,
        routing_table
      ]
      |> Enum.join(" ")

    [
      {"PreUp", "#{rat_config.hooks.pre_up} #{args}"},
      {"PostUp", "#{rat_config.hooks.post_up} #{args}"},
      {"PreDown", "#{rat_config.hooks.pre_down} #{args}"},
      {"PostDown", "#{rat_config.hooks.post_down} #{args}"}
    ]
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

defmodule Peridiod.Cloud do
  use GenServer

  require Logger

  alias Peridiod.{Bundle, Release, Cloud}
  alias PeridiodPersistence.KV

  def start_link(config, genserver_opts \\ [name: __MODULE__]) do
    GenServer.start_link(__MODULE__, config, genserver_opts)
  end

  def get_client(pid_or_name \\ __MODULE__) do
    GenServer.call(pid_or_name, :get_client)
  end

  def get_device_api_ip_cache(pid_or_name \\ __MODULE__) do
    GenServer.call(pid_or_name, :get_device_api_ip_cache)
  end

  def update_client_headers(pid_or_name \\ __MODULE__, opts) do
    GenServer.call(pid_or_name, {:update_client_headers, opts})
  end

  def get_tls_opts(pid_or_name \\ __MODULE__) do
    GenServer.call(pid_or_name, :get_tls_opts)
  end

  def update_tls_opts(pid_or_name \\ __MODULE__, opts) do
    GenServer.call(pid_or_name, {:update_tls_opts, opts})
  end

  def bind_tunnel_interface(pid_or_name \\ __MODULE__, ifname) do
    GenServer.cast(pid_or_name, {:bind_tunnel_interface, ifname})
  end

  defdelegate check_for_update(), to: Cloud.Update

  def init(config) do
    adapter = {Tesla.Adapter.Mint, timeout: 10_000, transport_opts: config.ssl}

    via_prn =
      case KV.get("peridio_via_current") do
        nil -> KV.get("peridio_rel_current")
        "" -> nil
        val -> val
      end

    bundle_prn = KV.get("peridio_bun_current")

    case KV.get("peridio_bun_current") do
      nil -> nil
      "" -> nil
      val -> val
    end

    release_version =
      case KV.get("peridio_vsn_current") do
        nil -> KV.get_active("peridio_version")
        "" -> nil
        val -> val
      end

    ifname = Cloud.NetworkMonitor.get_bound_interface()

    client =
      PeridioSDK.Client.new(
        # device_api_host: "https://#{config.device_api_host}",
        device_api_host: "https://#{config.device_api_host}:#{config.device_api_port}",
        adapter: adapter,
        user_agent: user_agent()
      )
      |> do_update_client_headers(
        bundle_prn: bundle_prn,
        via_prn: via_prn,
        release_version: release_version
      )

    tls_opts = if ifname, do: Keyword.put(config.ssl, :bind_to_device, ifname), else: config.ssl
    client = do_update_client_transport_opts(client, tls_opts)

    {:ok,
     %{
       client: client,
       tls_opts: tls_opts,
       device_api_host: config.device_api_host,
       device_api_ip_cache: [],
       rat_config: config.remote_access_tunnels
     }}
  end

  def handle_call(:get_client, _from, state) do
    send(self(), :update_dns_ip_cache)
    ifname = Cloud.NetworkMonitor.get_bound_interface()
    tls_opts = add_bound_interface(ifname, state.tls_opts)
    client = do_update_client_transport_opts(state.client, tls_opts)
    {:reply, client, state}
  end

  def handle_call(:get_device_api_ip_cache, _from, state) do
    {:reply, state.device_api_ip_cache, state}
  end

  def handle_call({:update_client_headers, opts}, _from, state) do
    client = do_update_client_headers(state.client, opts)
    {:reply, client, %{state | client: client}}
  end

  def handle_call(:get_tls_opts, _from, state) do
    ifname = Cloud.NetworkMonitor.get_bound_interface()
    tls_opts = add_bound_interface(ifname, state.tls_opts)
    {:reply, tls_opts, state}
  end

  def handle_call({:update_tls_opts, tls_opts}, _from, state) do
    client = do_update_client_transport_opts(state.client, tls_opts)
    {:reply, :ok, %{state | tls_opts: tls_opts, client: client}}
  end

  def handle_cast({:bind_tunnel_interface, ifname}, state) do
    Logger.info("[Cloud] Re-binding Active Tunnels")
    Cloud.Tunnel.update_bind_interface(ifname, state.rat_config)
    {:noreply, state}
  end

  def handle_info(:update_dns_ip_cache, state) do
    Logger.info("[Cloud] Update DNS IP Cache")
    {:noreply, update_dns_ip_cache(state)}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp update_dns_ip_cache(state) do
    addresses =
      state.device_api_host
      |> to_charlist()
      |> :inet_res.lookup(:in, :a, timeout: 1000)
      |> Enum.map(&Peridio.NetMon.IP.ip_to_string/1)

    case addresses do
      [] ->
        Logger.debug("[Cloud] DNS lookup returned no addresses, keeping existing cache")
        state

      _ ->
        Logger.debug("[Cloud] DNS lookup returned #{length(addresses)} addresses")
        %{state | device_api_ip_cache: addresses}
    end
  end

  defp do_update_client_headers(client, headers) do
    bundle_prn = headers[:bundle_prn]
    via_prn = headers[:via_prn]
    release_version = headers[:release_version]

    client =
      client
      |> Map.put(:bundle_prn, sanitize(bundle_prn))
      |> Map.put(:release_version, sanitize(release_version))

    case Bundle.via(via_prn) do
      Release -> Map.put(client, :release_prn, via_prn)
      _ -> Map.put(client, :release_prn, nil)
    end
  end

  defp do_update_client_transport_opts(%{adapter: {mod, opts}} = client, tls_opts) do
    %{client | adapter: {mod, Keyword.put(opts, :transport_opts, tls_opts)}}
  end

  defp sanitize(""), do: nil
  defp sanitize(val), do: val

  defp user_agent() do
    {os_family, os_type} = :erlang.system_info(:os_type)
    arch = :erlang.system_info(:system_architecture)
    version = Peridiod.version()
    otp_version = :erlang.system_info(:otp_release) |> to_string()
    elixir_version = System.version()

    "peridiod/#{version} (#{os_family},#{os_type}; #{arch}) OTP/#{otp_version} Elixir/#{elixir_version}"
  end

  defp add_bound_interface(nil, tls_opts), do: Keyword.delete(tls_opts, :bind_to_device)
  defp add_bound_interface(ifname, tls_opts), do: Keyword.put(tls_opts, :bind_to_device, ifname)
end

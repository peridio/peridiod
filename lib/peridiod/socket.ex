defmodule Peridiod.Socket do
  use Slipstream
  require Logger

  alias Peridiod.Client
  alias Peridiod.UpdateManager
  alias Peridiod.Configurator
  alias Peridiod.RemoteConsole

  @rejoin_after Application.compile_env(:peridiod, :rejoin_after, 5_000)

  defmodule State do
    @type t :: %__MODULE__{
            channel: pid(),
            connected?: boolean(),
            params: map(),
            socket: pid(),
            topic: String.t()
          }

    defstruct socket: nil,
              topic: "device",
              channel: nil,
              params: %{},
              connected?: false
  end

  @console_topic "console"
  @device_topic "device"

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def reconnect() do
    GenServer.cast(__MODULE__, :reconnect)
  end

  def send_update_progress(progress) do
    GenServer.cast(__MODULE__, {:send_update_progress, progress})
  end

  def send_update_status(status) do
    GenServer.cast(__MODULE__, {:send_update_status, status})
  end

  def check_connection(type) do
    GenServer.call(__MODULE__, {:check_connection, type})
  end

  @impl Slipstream
  def init(nil) do
    config = Configurator.get_config()

    opts = [
      mint_opts: [protocols: [:http1], transport_opts: config.ssl],
      uri: config.socket[:url],
      rejoin_after_msec: [@rejoin_after],
      reconnect_after_msec: config.socket[:reconnect_after_msec]
    ]

    socket =
      new_socket()
      |> assign(params: config.params)
      |> assign(remote_iex: config.remote_iex)
      |> assign(remote_shell: config.remote_shell)
      |> assign(remote_console_pid: nil)
      |> assign(remote_console_timer: nil)
      |> connect!(opts)

    Process.flag(:trap_exit, true)

    {:ok, socket}
  end

  @impl Slipstream
  def handle_connect(socket) do
    currently_downloading_uuid = UpdateManager.currently_downloading_uuid()

    device_join_params =
      socket.assigns.params
      |> Map.put("currently_downloading_uuid", currently_downloading_uuid)

    socket =
      socket
      |> join(@device_topic, device_join_params)
      |> maybe_join_console()

    {:ok, socket}
  end

  @impl Slipstream
  def handle_join(@device_topic, reply, socket) do
    Logger.debug("[#{inspect(__MODULE__)}] Joined Device channel")
    Peridiod.Connection.connected()
    _ = handle_join_reply(reply)
    {:ok, socket}
  end

  def handle_join(@console_topic, _reply, socket) do
    protocol = if socket.assigns.remote_iex, do: "IEx", else: "getty"
    Logger.debug("[#{inspect(__MODULE__)}] Joined Console channel: #{protocol}")
    {:ok, socket}
  end

  @impl Slipstream
  def handle_call({:check_connection, :console}, _from, socket) do
    {:reply, joined?(socket, @console_topic), socket}
  end

  def handle_call({:check_connection, :device}, _from, socket) do
    {:reply, joined?(socket, @device_topic), socket}
  end

  def handle_call({:check_connection, :socket}, _from, socket) do
    {:reply, connected?(socket), socket}
  end

  @impl Slipstream
  def handle_cast(:reconnect, socket) do
    # See handle_disconnect/2 for the reconnect call once the connection is
    # closed.
    {:noreply, disconnect(socket)}
  end

  def handle_cast({:send_update_progress, progress}, socket) do
    _ = push(socket, @device_topic, "fwup_progress", %{value: progress})
    {:noreply, socket}
  end

  def handle_cast({:send_update_status, status}, socket) do
    _ = push(socket, @device_topic, "status_update", %{status: status})
    {:noreply, socket}
  end

  @impl Slipstream
  ##
  # Device API messages
  #
  def handle_message(@device_topic, "reboot", _params, socket) do
    Logger.warning("Reboot Request from Peridiod")
    _ = push(socket, @device_topic, "rebooting", %{})

    System.cmd("reboot", [], stderr_to_stdout: true)
    {:ok, socket}
  end

  def handle_message(
        @console_topic,
        "window_size",
        %{"height" => height, "width" => width},
        socket
      ) do
    if socket.assigns.remote_iex do
      RemoteConsole.IEx.window_change(socket.assigns.remote_console_pid, width, height)
    end

    {:ok, socket}
  end

  def handle_message(@device_topic, "update", update, socket) do
    case Peridiod.Message.UpdateInfo.parse(update) do
      {:ok, %Peridiod.Message.UpdateInfo{} = info} ->
        _ = UpdateManager.apply_update(info)
        {:ok, socket}

      error ->
        Logger.error("Error parsing update data: #{inspect(update)} error: #{inspect(error)}")
        {:ok, socket}
    end
  end

  def handle_message(@device_topic, "tunnel_request", %{"tunnel_prn" => tunnel_prn}, socket) do
    config = Peridiod.Configurator.get_config()
    opts =
      [
        device_api_host: "https://#{config.device_api_host}",
        ssl: config.ssl,
        dport: 22,
        ipv4_cidrs: config.remote_access_tunnels.ipv4_cidrs,
        port_range: config.remote_access_tunnels.port_range
      ]

    interface =
      Peridio.RAT.WireGuard.generate_key_pair()
      |> Peridio.RAT.WireGuard.Interface.new()

    case Peridiod.Tunnel.configure_request(opts, interface, tunnel_prn) do
      {:ok, resp} ->
        {:ok, expires_at, _} = DateTime.from_iso8601(resp.body["data"]["expires_at"])
        IO.puts resp.body["data"]["expires_at"]
        IO.inspect DateTime.utc_now()
        peer = %Peridio.RAT.WireGuard.Peer{
          ip_address: resp.body["data"]["server_proxy_ip_address"],
          endpoint: resp.body["data"]["server_tunnel_ip_address"],
          port: resp.body["data"]["server_proxy_port"],
          public_key: resp.body["data"]["server_public_key"],
          persistent_keepalive: config.remote_access_tunnels.persistent_keepalive
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
        PreUp = #{config.remote_access_tunnels.hooks.pre_up} #{args}
        PostUp = #{config.remote_access_tunnels.hooks.post_up} #{args}
        PreDown = #{config.remote_access_tunnels.hooks.pre_down} #{args}
        PostDown = #{config.remote_access_tunnels.hooks.post_down} #{args}
        """

        Peridio.RAT.open_tunnel(interface, peer, expires_at: expires_at, hooks: hooks)

      error ->
        Logger.error("Remote Tunnel Error #{inspect(error)}")
    end

    {:ok, socket}
  end

  ##
  # Console API messages
  #
  def handle_message(@console_topic, "restart", _payload, socket) do
    protocol = if socket.assigns.remote_iex, do: "IEx", else: "getty"
    Logger.warning("[#{inspect(__MODULE__)}] Restarting #{protocol} process from web request")
    _ = push(socket, @console_topic, "up", %{data: "\r*** Restarting #{protocol} ***\r"})

    socket =
      socket
      |> stop_remote_console()
      |> start_remote_console()

    {:ok, socket}
  end

  def handle_message(
        @console_topic,
        message,
        payload,
        %{assigns: %{remote_console_pid: nil}} = socket
      ) do
    stop_remote_console(socket)
    handle_message(@console_topic, message, payload, start_remote_console(socket))
  end

  def handle_message(
        @console_topic,
        "dn",
        %{"data" => data},
        %{assigns: %{remote_shell: true}} = socket
      ) do
    RemoteConsole.Getty.send_data(socket.assigns.remote_console_pid, data)
    {:ok, socket}
  end

  def handle_message(
        @console_topic,
        "dn",
        %{"data" => data},
        %{assigns: %{remote_iex: true}} = socket
      ) do
    RemoteConsole.IEx.send_data(socket.assigns.remote_console_pid, data)
    {:ok, socket}
  end

  @impl Slipstream
  def handle_info({:remote_console, _, :timeout}, socket) do
    msg = """
    \r
    ****************************************\r
    *   Session timeout due to inactivity  *\r
    *                                      *\r
    *   Press any key to continue...       *\r
    ****************************************\r
    """

    _ = push(socket, @console_topic, "up", %{data: msg})

    {:noreply, stop_remote_console(socket)}
  end

  def handle_info({:remote_console, _, {:error, error}}, socket) do
    msg = "\r******* Remote Console stopped: #{inspect(error)} *******\r"
    _ = push(socket, @console_topic, "up", %{data: msg})
    Logger.warning(msg)

    socket =
      socket
      |> stop_remote_console()
      |> start_remote_console()

    {:noreply, socket}
  end

  def handle_info({:remote_console, _pid, data}, socket) do
    data = remove_unwanted_chars(data)
    _ = push(socket, @console_topic, "up", %{data: data})
    {:noreply, socket}
  end

  def handle_info({:EXIT, _pid, :normal}, socket) do
    {:noreply, socket}
  end

  def handle_info(msg, socket) do
    Logger.warning("[#{inspect(__MODULE__)}] Unhandled handle_info: #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl Slipstream
  def handle_topic_close(topic, reason, socket) when reason != :left do
    if topic == @device_topic do
      _ = Peridiod.Connection.disconnected()
      _ = Client.handle_error(reason)
    end

    rejoin(socket, topic, socket.assigns.params)
  end

  @impl Slipstream
  def handle_disconnect(reason, socket) do
    _ = Client.handle_error(reason)
    reconnect(socket)
  end

  @impl Slipstream
  def terminate(_reason, socket) do
    _ = Peridiod.Connection.disconnected()
    disconnect(socket)
  end

  defp handle_join_reply(%{"firmware_url" => url} = update) when is_binary(url) do
    case Peridiod.Message.UpdateInfo.parse(update) do
      {:ok, %Peridiod.Message.UpdateInfo{} = info} ->
        UpdateManager.apply_update(info)

      error ->
        Logger.error("Error parsing update data: #{inspect(update)} error: #{inspect(error)}")
        :noop
    end
  end

  defp handle_join_reply(_), do: :noop

  defp maybe_join_console(socket) do
    if socket.assigns.remote_iex || socket.assigns.remote_shell do
      join(socket, @console_topic, socket.assigns.params)
    else
      socket
    end
  end

  defp start_remote_console(%{assigns: %{remote_iex: true}} = socket) do
    Logger.info("Remote Console: Start IEx")
    {:ok, iex_pid} = RemoteConsole.IEx.start_link([])
    assign(socket, remote_console_pid: iex_pid)
  end

  defp start_remote_console(%{assigns: %{remote_shell: true}} = socket) do
    Logger.debug("Remote Console: Start getty")
    {:ok, getty_pid} = RemoteConsole.Getty.start_link([])
    assign(socket, remote_console_pid: getty_pid)
  end

  defp stop_remote_console(%{assigns: %{remote_console_pid: nil}} = socket), do: socket

  defp stop_remote_console(%{assigns: %{remote_iex: true, remote_console_pid: iex_pid}} = socket) do
    _ = if Process.alive?(iex_pid), do: RemoteConsole.IEx.stop(iex_pid)

    socket
    |> assign(remote_console_pid: nil)
  end

  defp stop_remote_console(
         %{assigns: %{remote_shell: true, remote_console_pid: getty_pid}} = socket
       ) do
    _ = if Process.alive?(getty_pid), do: RemoteConsole.Getty.stop(getty_pid)

    socket
    |> assign(remote_console_pid: nil)
  end

  defp remove_unwanted_chars(input) when is_binary(input) do
    input
    |> String.codepoints()
    |> Enum.filter(&valid_codepoint?/1)
    |> Enum.join()
  end

  defp valid_codepoint?(<<_::utf8>>), do: true
  defp valid_codepoint?(_), do: false
end

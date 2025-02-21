defmodule Peridiod.Cloud.Socket do
  use Slipstream
  require Logger

  alias Peridiod.{Client, Distribution, RemoteConsole, Utils, Cloud}
  alias Peridiod.Binary.Installer.Fwup
  alias PeridiodPersistence.KV

  @rejoin_after Application.compile_env(:peridiod, :rejoin_after, 5_000)
  @device_api_version "1.0.0"
  @console_version "1.0.0"

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

  def start_link(config) do
    GenServer.start_link(__MODULE__, config, name: __MODULE__)
  end

  def stop() do
    try_cast(__MODULE__, :stop)
  end

  def reconnect() do
    try_cast(__MODULE__, :reconnect)
  end

  def send_binary_progress(binary_progress_map) do
    try_cast(__MODULE__, {:send_binary_progress, binary_progress_map})
  end

  def send_distribution_progress(progress) do
    try_cast(__MODULE__, {:send_distribution_progress, progress})
  end

  def send_distribution_status(status) do
    try_cast(__MODULE__, {:send_distribution_status, status})
  end

  def check_connection(type) do
    GenServer.call(__MODULE__, {:check_connection, type})
  end

  def try_cast(pid_or_name, message) do
    case GenServer.whereis(pid_or_name) do
      nil -> :ok
      pid -> GenServer.cast(pid, message)
    end
  end

  @impl Slipstream
  def init(config) do
    tls_opts = Cloud.get_tls_opts()

    opts = [
      mint_opts: [protocols: [:http1], transport_opts: tls_opts],
      uri: config.socket[:url],
      rejoin_after_msec: [@rejoin_after],
      reconnect_after_msec: config.socket[:reconnect_after_msec]
    ]

    peridio_uuid =
      KV.get_active("peridio_uuid") || KV.get_active("nerves_fw_uuid")

    params =
      KV.get_all_active()
      |> Map.put("nerves_fw_uuid", peridio_uuid)
      |> Map.put("device_api_version", @device_api_version)
      |> Map.put("console_version", @console_version)

    params =
      case Utils.exec_installed?("fwup") do
        true -> Map.put(params, "fwup_version", Fwup.version())
        false -> params
      end

    socket =
      new_socket()
      |> assign(params: params)
      |> assign(device_api_host: config.device_api_host)
      |> assign(remote_iex: config.remote_iex)
      |> assign(remote_shell: config.remote_shell)
      |> assign(remote_access_tunnels: config.remote_access_tunnels)
      |> assign(remote_console_pid: nil)
      |> assign(remote_console_timer: nil)
      |> connect!(opts)

    Process.flag(:trap_exit, true)

    {:ok, socket}
  end

  @impl Slipstream
  def handle_connect(socket) do
    currently_downloading_uuid = Distribution.Server.currently_downloading_uuid()

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
    Logger.info("[Cloud Socket] Joined Device channel")
    Cloud.Connection.connected()
    _ = handle_join_reply(reply)
    send(self(), :tunnel_synchronize)
    {:ok, socket}
  end

  def handle_join(@console_topic, _reply, socket) do
    protocol = if socket.assigns.remote_iex, do: "IEx", else: "getty"
    Logger.info("[Cloud Socket] Joined Console channel: #{protocol}")
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

  def handle_cast({:send_binary_progress, binary_progress_map}, socket)
      when is_map(binary_progress_map) and map_size(binary_progress_map) == 0 do
    {:noreply, socket}
  end

  def handle_cast({:send_binary_progress, binary_progress_map}, socket) do
    _ =
      push(socket, @device_topic, "binary_progress", %{
        id: UUID.uuid4(),
        published_at: DateTime.utc_now() |> DateTime.to_iso8601(),
        type: "binary_progress",
        binaries: binary_progress_map
      })

    {:noreply, socket}
  end

  def handle_cast({:send_distribution_progress, progress}, socket) do
    _ = push(socket, @device_topic, "fwup_progress", %{value: progress})
    {:noreply, socket}
  end

  def handle_cast({:send_distribution_status, status}, socket) do
    _ = push(socket, @device_topic, "status_update", %{status: status})
    {:noreply, socket}
  end

  def handle_cast(:stop, socket) do
    {:stop, :normal, disconnect(socket)}
  end

  @impl Slipstream
  ##
  # Device API messages
  #
  def handle_message(@device_topic, "reboot", _params, socket) do
    Logger.warning("[Cloud Socket] Reboot Request")
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
    case Peridiod.Distribution.parse(update) do
      {:ok, %Peridiod.Distribution{} = info} ->
        _ = Distribution.Server.apply_update(info)
        {:ok, socket}

      error ->
        Logger.error(
          "[Cloud Socket] Error parsing update data: #{inspect(update)} error: #{inspect(error)}"
        )

        {:ok, socket}
    end
  end

  def handle_message(
        @device_topic,
        "tunnel_request",
        %{"tunnel_prn" => tunnel_prn} = payload,
        %{assigns: %{remote_access_tunnels: %{enabled: false}}} = socket
      ) do
    Logger.warning(
      "[Cloud Socket] Remote Access Tunnel requested but not enabled on the device: #{inspect(payload)}"
    )

    Cloud.Tunnel.close(tunnel_prn, "feature_not_enabled")
    {:ok, socket}
  end

  def handle_message(
        @device_topic,
        "tunnel_request",
        %{"tunnel_prn" => tunnel_prn, "device_tunnel_port" => dport},
        socket
      ) do
    service_ports = socket.assigns.remote_access_tunnels.service_ports

    if dport in service_ports do
      device_client = Cloud.get_client()

      case Cloud.Tunnel.create(
             device_client,
             tunnel_prn,
             dport,
             socket.assigns.remote_access_tunnels
           ) do
        {:ok, _state} ->
          :ok

        error ->
          Logger.error("[Socket] Tunnel Open Error: #{inspect(error)}")
          Cloud.Tunnel.close(tunnel_prn, "server_error_create")
      end
    else
      Logger.warning(
        "[Cloud Socket] Remote Access Tunnel requested for port #{dport} but not enabled in service port list: #{inspect(service_ports)}"
      )

      Cloud.Tunnel.close(tunnel_prn, "dport_not_allowed")
    end

    {:ok, socket}
  end

  def handle_message(
        @device_topic,
        "tunnel_extend",
        _request,
        %{assigns: %{remote_access_tunnels: %{enabled: false}}} = socket
      ) do
    {:ok, socket}
  end

  def handle_message(
        @device_topic,
        "tunnel_extend",
        %{"tunnel_prn" => tunnel_prn, "expires_at" => expires_at},
        socket
      ) do
    {:ok, expires_at, _offset} = DateTime.from_iso8601(expires_at)
    Logger.info("[Cloud Socket] Tunnel Server requested extend")
    Peridio.RAT.extend_tunnel(tunnel_prn, expires_at)
    {:ok, socket}
  end

  def handle_message(
        @device_topic,
        "tunnel_close",
        _request,
        %{assigns: %{remote_access_tunnels: %{enabled: false}}} = socket
      ) do
    {:ok, socket}
  end

  def handle_message(@device_topic, "tunnel_close", %{"tunnel_prn" => tunnel_prn}, socket) do
    Logger.info("[Cloud Socket] Tunnel Server requested close")
    Cloud.Tunnel.close(tunnel_prn, "server_requested_close")
    {:ok, socket}
  end

  ##
  # Console API messages
  #
  def handle_message(@console_topic, "restart", _payload, socket) do
    protocol = if socket.assigns.remote_iex, do: "IEx", else: "getty"
    Logger.warning("[Cloud Socket] Restarting #{protocol} process from web request")
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
    Logger.warning("[Cloud Socket] Remote console stopped #{inspect(msg)}")

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

  def handle_info(:tunnel_synchronize, socket) do
    Logger.info("[Cloud Socket] Tunnels synchronizing")
    device_client = Cloud.get_client()
    Cloud.Tunnel.synchronize(device_client, socket.assigns.remote_access_tunnels)
    {:noreply, socket}
  end

  def handle_info({:EXIT, _pid, :normal}, socket) do
    {:noreply, socket}
  end

  def handle_info(msg, socket) do
    Logger.warning("[Cloud Socket] Unhandled handle_info: #{inspect(msg)}")
    {:noreply, socket}
  end

  @impl Slipstream
  def handle_topic_close(topic, reason, socket) when reason != :left do
    if topic == @device_topic do
      _ = Cloud.Connection.disconnected()
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
    _ = Cloud.Connection.disconnected()
    disconnect(socket)
  end

  defp handle_join_reply(%{"firmware_url" => url} = update) when is_binary(url) do
    case Peridiod.Distribution.parse(update) do
      {:ok, %Peridiod.Distribution{} = info} ->
        Distribution.Server.apply_update(info)

      error ->
        Logger.error(
          "[Cloud Socket] Error parsing update data: #{inspect(update)} error: #{inspect(error)}"
        )

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
    Logger.info("[Cloud Socket] Remote Console: Starting IEx")
    {:ok, iex_pid} = RemoteConsole.IEx.start_link([])
    assign(socket, remote_console_pid: iex_pid)
  end

  defp start_remote_console(%{assigns: %{remote_shell: true}} = socket) do
    Logger.info("[Cloud Socket] Remote Console: Starting shell")
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

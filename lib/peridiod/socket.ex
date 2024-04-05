defmodule Peridiod.Socket do
  use Slipstream
  require Logger

  alias Peridiod.Client
  alias Peridiod.UpdateManager
  alias Peridiod.Configurator

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
      |> assign(getty_pid: nil)
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
    Logger.debug("[#{inspect(__MODULE__)}] Joined Console channel")
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
        %{"height" => _height, "width" => _width},
        socket
      ) do
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

  ##
  # Console API messages
  #
  def handle_message(@console_topic, "restart", _payload, socket) do
    Logger.warning("[#{inspect(__MODULE__)}] Restarting IEx process from web request")

    _ = push(socket, @console_topic, "up", %{data: "\r*** Restarting IEx ***\r"})

    socket =
      socket
      |> stop_getty()
      |> start_getty()

    {:ok, socket}
  end

  def handle_message(@console_topic, message, payload, %{assigns: %{getty_pid: nil}} = socket) do
    stop_getty(socket)
    handle_message(@console_topic, message, payload, start_getty(socket))
  end

  def handle_message(@console_topic, "dn", %{"data" => data}, socket) do
    Peridiod.Getty.send_data(socket.assigns.getty_pid, data)
    {:ok, socket}
  end

  @impl Slipstream
  def handle_info({:tty_data, data}, socket) do
    data = remove_unwanted_chars(data)
    _ = push(socket, @console_topic, "up", %{data: data})
    {:noreply, socket}
  end

  def handle_info({:getty, _, :timeout}, socket) do
    msg = """
    \r
    ****************************************\r
    *   Session timeout due to inactivity  *\r
    *                                      *\r
    *   Press any key to continue...       *\r
    ****************************************\r
    """

    _ = push(socket, @console_topic, "up", %{data: msg})

    {:noreply, stop_getty(socket)}
  end

  def handle_info({:getty, _, {:error, :eio}}, socket) do
    msg = "\r******* Remote Console stopped: eio *******\r"
    _ = push(socket, @console_topic, "up", %{data: msg})
    Logger.warning(msg)

    socket =
      socket
      |> stop_getty()
      |> start_getty()

    {:noreply, socket}
  end

  def handle_info({:getty, _pid, data}, socket) do
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
    if socket.assigns.remote_iex do
      join(socket, @console_topic, socket.assigns.params)
    else
      socket
    end
  end

  defp start_getty(socket) do
    Logger.debug("Start getty")
    {:ok, getty_pid} = Peridiod.Getty.start_link([])

    socket
    |> assign(getty_pid: getty_pid)
  end

  defp stop_getty(%{assigns: %{getty_pid: nil}} = socket), do: socket

  defp stop_getty(%{assigns: %{getty_pid: getty_pid}} = socket) do
    _ = if Process.alive?(getty_pid), do: Peridiod.Getty.stop(getty_pid)

    socket
    |> assign(getty_pid: nil)
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

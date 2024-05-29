defmodule Peridiod.RemoteConsole.Getty do
  use GenServer

  require Logger

  @tty_pair {"ttyPeridio0", "ttyPeridio1"}
  # 5 minutes
  @timeout 300_000

  def start_link(opts) do
    opts = Keyword.put_new(opts, :callback, self())
    GenServer.start_link(__MODULE__, opts)
  end

  def stop(pid) do
    GenServer.stop(pid)
  end

  def send_data(pid, data) do
    GenServer.call(pid, {:send_data, data})
  end

  def window_change(_width, _height) do
    :ok
  end

  @impl true
  def init(opts) do
    send(self(), :start)
    timeout = opts[:timeout] || @timeout

    {:ok,
     %{
       status: :starting,
       tty_pair: opts[:tty_pair] || @tty_pair,
       getty_pid: nil,
       pty_pid: nil,
       uart_pid: nil,
       queue: [],
       callback: opts[:callback],
       timeout: timeout
     }}
  end

  @impl true
  def handle_call({:send_data, data}, _from, %{uart_pid: nil} = state) do
    {:reply, :ok, %{state | queue: [data] ++ state.queue}, state.timeout}
  end

  def handle_call({:send_data, data}, _from, %{uart_pid: uart_pid} = state) do
    {:reply, Circuits.UART.write(uart_pid, data), state, state.timeout}
  end

  @impl true
  def handle_info(:start, %{status: :starting, pty_pid: nil, tty_pair: {tty_l, tty_h}} = state) do
    {:ok, pty_pid, sys_pid} = start_pty(tty_l, tty_h)
    send(self(), :start)
    {:noreply, %{state | pty_pid: {pty_pid, sys_pid}}}
  end

  def handle_info(:start, %{status: :starting, getty_pid: nil, tty_pair: {tty_l, tty_h}} = state) do
    file = "/dev/#{tty_l}"

    case File.exists?(file) do
      true ->
        {:ok, getty_pid, sys_pid} = start_getty(tty_l)
        {:ok, uart_pid} = start_uart(tty_h)
        send(self(), :start)
        {:noreply, %{state | getty_pid: {getty_pid, sys_pid}, uart_pid: uart_pid}}

      false ->
        Process.send_after(self(), :start, 100)
        {:noreply, state}
    end
  end

  def handle_info(:start, state) do
    Enum.each(state.queue, &Circuits.UART.write(state.uart_pid, &1))
    {:noreply, %{state | status: :running}}
  end

  def handle_info({:circuits_uart, _pid, data}, state) do
    send(state.callback, {:remote_console, self(), data})
    {:noreply, state, state.timeout}
  end

  def handle_info(
        {:DOWN, _, _, getty_pid, _},
        %{getty_pid: {getty_pid, _}, tty_pair: {tty_l, _}} = state
      ) do
    {:ok, getty_pid, sys_pid} = start_getty(tty_l)
    {:noreply, %{state | getty_pid: {getty_pid, sys_pid}}}
  end

  def handle_info(:timeout, %{getty_pid: {_, getty_pid}, pty_pid: {_, pty_pid}} = state) do
    :exec.stop(getty_pid)
    GenServer.stop(state.uart_pid)
    :exec.stop(pty_pid)
    send(state.callback, {:remote_console, self(), :timeout})
    {:stop, :normal, state}
  end

  def start_getty(tty_l) do
    :exec.run(
      ~c"setsid /sbin/agetty -o '-p -- \\u' --keep-baud 115200 #{tty_l} #{System.get_env("TERM", "linux")}",
      [:monitor]
    )
  end

  def start_pty(tty_l, tty_h) do
    :exec.run(
      ~c"socat -d -d PTY,raw,echo=0,link=/dev/#{tty_l} PTY,raw,echo=0,link=/dev/#{tty_h}",
      [:monitor]
    )
  end

  defp start_uart(tty_h) do
    {:ok, uart_pid} = Circuits.UART.start_link()
    Circuits.UART.open(uart_pid, tty_h, speed: 115_200, active: true)
    {:ok, uart_pid}
  end
end

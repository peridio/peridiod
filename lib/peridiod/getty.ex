defmodule Peridiod.Getty do
  use GenServer

  require Logger

  @tty_pair {"ttyPeridio0", "ttyPeridio1"}
  @timeout 300_000 #5 minutes

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

  @impl true
  def init(opts) do
    send(self(), :start)
    timeout = opts[:timeout] || @timeout
    {:ok, %{
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
    {:ok, pid} = start_pty(tty_l, tty_h)
    send(self(), :start)
    {:noreply, %{state | pty_pid: pid}}
  end

  def handle_info(:start, %{status: :starting, getty_pid: nil, tty_pair: {tty_l, tty_h}} = state) do
    file = "/dev/#{tty_l}"
    case File.exists?(file) do
      true ->
        {:ok, getty_pid} = start_getty(tty_l)
        Process.monitor(getty_pid)
        {:ok, uart_pid} = start_uart(tty_h)
        send(self(), :start)
        {:noreply, %{state | getty_pid: getty_pid, uart_pid: uart_pid}}
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
    send(state.callback, {:getty, self(), data})
    {:noreply, state, state.timeout}
  end

  def handle_info({:DOWN, _, _, getty_pid, _}, %{getty_pid: getty_pid, tty_pair: {tty_l, _}} = state) do
    {:ok, getty_pid} = start_getty(tty_l)
    Process.monitor(getty_pid)
    {:noreply, %{state | getty_pid: getty_pid}}
  end

  def handle_info(:timeout, state) do
    GenServer.stop(state.getty_pid)
    GenServer.stop(state.uart_pid)
    GenServer.stop(state.pty_pid)
    send(state.callback, {:getty, self(), :timeout})
    {:stop, :normal, state}
  end

  defp start_getty(tty_l) do
    MuonTrap.Daemon.start_link("setsid", [
      "/sbin/agetty",
      "-o",
      "-p -- \\u",
      "--keep-baud",
      "115200",
      tty_l,
      System.get_env("TERM", "linux")
    ])
  end

  defp start_pty(tty_l, tty_h) do
    MuonTrap.Daemon.start_link("socat", [
      "-d",
      "-d",
      "PTY,raw,echo=0,link=/dev/#{tty_l}",
      "PTY,raw,echo=0,link=/dev/#{tty_h}"
    ])
  end

  defp start_uart(tty_h) do
    {:ok, uart_pid} = Circuits.UART.start_link()
    Circuits.UART.open(uart_pid, tty_h, speed: 115_200, active: true)
    {:ok, uart_pid}
  end
end

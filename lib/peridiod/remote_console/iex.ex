defmodule Peridiod.RemoteConsole.IEx do
  use GenServer

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
    GenServer.cast(pid, {:send_data, data})
  end

  def window_change(pid, width, height) do
    GenServer.cast(pid, {:window_change, width, height})
  end

  def init(opts) do
    timeout = opts[:timeout] || @timeout
    shell_opts = [[dot_iex_path: dot_iex_path()]]
    {:ok, iex_pid} = ExTTY.start_link(handler: self(), type: :elixir, shell_opts: shell_opts)

    {:ok,
     %{
       iex_pid: iex_pid,
       iex_timer: Process.send_after(self(), :iex_timeout, timeout),
       queue: [],
       callback: opts[:callback],
       timeout: timeout
     }}
  end

  def handle_cast({:send_data, data}, %{iex_pid: iex_pid} = state) do
    _ = ExTTY.send_text(iex_pid, data)
    {:noreply, set_iex_timer(state)}
  end

  def handle_cast({:window_change, width, height}, %{iex_pid: iex_pid} = state) do
    _ = ExTTY.window_change(iex_pid, width, height)
    {:noreply, set_iex_timer(state)}
  end

  def handle_info(:iex_timeout, state) do
    GenServer.stop(state.iex_pid)
    send(state.callback, {:remote_console, self(), :timeout})
    {:stop, :normal, state}
  end

  def handle_info({:tty_data, data}, state) do
    send(state.callback, {:remote_console, self(), data})
    {:noreply, set_iex_timer(state)}
  end

  defp set_iex_timer(%{iex_timer: old_timer} = state) do
    _ = if old_timer, do: Process.cancel_timer(old_timer)
    %{state | iex_timer: Process.send_after(self(), :iex_timeout, state.timeout)}
  end

  defp dot_iex_path() do
    [".iex.exs", "~/.iex.exs", "/etc/iex.exs"]
    |> Enum.map(&Path.expand/1)
    |> Enum.find("", &File.regular?/1)
  end
end

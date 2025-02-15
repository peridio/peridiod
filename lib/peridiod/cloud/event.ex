defmodule Peridiod.Cloud.Event do
  use GenServer

  alias Peridiod.Cloud.Socket

  @binary_progress_interval 1500

  def start_link(opts, genserver_opts \\ [name: __MODULE__]) do
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  def put_binary_progress(pid_or_name \\ __MODULE__, binary_prn, progress) do
    GenServer.cast(pid_or_name, {:put_binary_progress, binary_prn, progress})
  end

  def init(_opts) do
    binary_progress_interval = @binary_progress_interval

    {:ok,
     %{
       binary_progress: %{},
       binary_progress_interval: binary_progress_interval,
       binary_progress_timer: nil
     }}
  end

  def handle_cast({:put_binary_progress, binary_prn, progress}, state) do
    binary_prn_progress =
      state.binary_progress
      |> Map.get(binary_prn, %{download_percent: 0.0, install_percent: 0.0})
      |> Map.merge(progress)

    binary_progress = Map.put(state.binary_progress, binary_prn, binary_prn_progress)
    {:noreply, %{state | binary_progress: binary_progress}}
  end

  def handle_info(:send_binary_progress, state) do
    Socket.send_binary_progress(state.binary_progress)
    timer_ref = Process.send_after(self(), :send_progress_message, @binary_progress_interval)
    {:noreply, %{state | binary_progress_timer: timer_ref, binary_progress: %{}}}
  end
end

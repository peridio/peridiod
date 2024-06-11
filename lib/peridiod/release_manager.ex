defmodule Peridiod.ReleaseManager do
  use GenServer

  require Logger

  alias Peridiod.Configurator

  @poll_interval 300_000

  @doc false
  @spec start_link(any()) :: GenServer.on_start()
  def start_link(_args) do
    GenServer.start_link(__MODULE__, nil, [name: __MODULE__])
  end

  def check_for_update() do
    GenServer.call(__MODULE__, :check_for_update)
  end

  @impl GenServer
  def init(nil) do
    config = Configurator.get_config()

    poll_interval = config.release_poll_interval || @poll_interval

    state = %{
      sdk_client: config.sdk_client,
      poll_interval: poll_interval
    }

    {:ok, state, {:continue, config.releases_enabled}}
  end

  @impl GenServer
  def handle_continue(true, state) do
    Logger.debug "ReleaseManager Enabled"
    do_update_check(state)
    {:noreply, state, state.poll_interval}
  end

  def handle_continue(false, state) do
    Logger.debug "ReleaseManager Disabled"
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:check_for_update, _from, state) do
    {:reply, do_update_check(state), state}
  end

  @impl GenServer
  def handle_info(:timeout, state) do
    Logger.debug "Polling interval time out"
    do_update_check(state)
    {:noreply, state, state.poll_interval}
  end

  defp do_update_check(%{sdk_client: client}) do
    Logger.debug "Do update check"
    PeridioSDK.DeviceAPI.Devices.update(client, ["manifest.url", "release.prn", "release.version"])
    |> do_update_response()
  end

  # An update is available, We should retreive the manifest and start downloading artifacts
  defp do_update_response({:ok, %{status: 200, body: %{"status" => "update", "manifest" => [%{"url" => url}]} = body}}) do
    Logger.debug "Release Manager: update"
  end

  defp do_update_response({:ok, %{status: 200, body: %{"status" => "no_update"}}}) do
    Logger.debug "Release Manager: no update"
    :no_update
  end
end

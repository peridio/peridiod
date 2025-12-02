defmodule Peridiod.Cloud.Shadow do
  use GenServer

  require Logger

  alias Peridiod.Cloud

  @interval 30 * 60 * 1000

  def start_link(config, genserver_opts \\ [name: __MODULE__]) do
    GenServer.start_link(__MODULE__, config, genserver_opts)
  end

  def init(config) do
    state = %{
      executable: config.shadow_executable,
      args: config.shadow_args,
      interval: config.shadow_interval,
      update_timer: nil
    }

    {:ok, state, {:continue, config.shadow_enabled}}
  end

  def handle_continue(true, state) do
    Logger.info("[Cloud Server] Shadow enabled")

    send(self(), :update_shadow)

    {:noreply, state}
  end

  def handle_continue(_, state) do
    Logger.info("[Cloud Server] Shadow Disabled")
    {:noreply, state}
  end

  def handle_call(:update_shadow, _from, state) do
    resp = do_update_shadow(state)

    {:reply, resp, state}
  end

  def handle_info(:update_shadow, state) do
    _ = do_update_shadow(state)
    update_timer = Process.send_after(self(), :update_shadow, state.interval)

    {:noreply, %{state | update_timer: update_timer}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp put_shadow(client, state) do
    case System.cmd(state.executable, state.args) do
      {output, 0} ->
        Logger.info("[Cloud Server] Uploading shadow")
        {:ok, PeridioSDK.DeviceAPI.Devices.shadow(client, Jason.decode!(output))}

      {error, code} ->
        {:error, "[Cloud Server] Executing shadow script failed with code #{code}: #{error}"}
    end
  end

  defp do_update_shadow(state) do
    Cloud.get_client()
    |> put_shadow(state)
    |> check_response(state)
  end

  defp check_response({:error, %{reason: :nxdomain}} = error, state) do
    case Cloud.get_device_api_ip_cache() do
      [] ->
        Logger.warning("[Cloud Server] DNS Cache Empty")
        error

      addresses ->
        address = Enum.random(addresses)
        Logger.warning("[Cloud Server] Using IP Address #{address}")

        Cloud.get_client()
        |> Map.put(:device_api_host, "https://#{address}")
        |> put_shadow(state)
    end
  end

  defp check_response(resp, _state), do: resp
end

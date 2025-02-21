defmodule Peridiod.Cloud.Update do
  use GenServer

  require Logger

  alias Peridiod.{Cloud, Update, BundleOverride, Release}

  @update_poll_interval 30 * 60 * 1000

  def start_link(config, genserver_opts \\ [name: __MODULE__]) do
    GenServer.start_link(__MODULE__, config, genserver_opts)
  end

  @spec check_for_update(pid() | atom()) ::
          :updating | :no_update | :device_quarantined | {:error, reason :: any}
  def check_for_update(pid_or_name \\ __MODULE__) do
    GenServer.call(pid_or_name, :check_for_update)
  end

  def init(config) do
    poll_interval = config.update_poll_interval || @update_poll_interval

    {:ok,
     %{
       poll_interval: poll_interval,
       update_timer: nil
     }, {:continue, config.update_poll_enabled}}
  end

  def handle_continue(true, state) do
    Logger.info("[Cloud Server] Polling enabled")

    send(self(), :check_for_update)

    update_timer = Process.send_after(self(), :check_for_update, state.poll_interval)

    {:noreply, %{state | update_timer: update_timer}}
  end

  def handle_continue(false, state) do
    Logger.info("[Cloud Server] Polling Disabled")
    {:noreply, state}
  end

  def handle_call(:check_for_update, _from, state) do
    client = Cloud.get_client()

    resp =
      update_check(client)
      |> update_response()

    {:reply, resp, state}
  end

  def handle_info(:check_for_update, state) do
    client = Cloud.get_client()

    update_check(client)
    |> update_response()

    update_timer = Process.send_after(self(), :check_for_update, state.poll_interval)

    {:noreply, %{state | update_timer: update_timer}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp update_check(client) do
    Logger.info("[Cloud Server] Checking for update")

    PeridioSDK.DeviceAPI.Devices.update(client, [
      "manifest.binary_prn",
      "manifest.custom_metadata",
      "manifest.hash",
      "manifest.target",
      "manifest.url",
      "manifest.signatures",
      "manifest.size",
      "manifest.artifact.prn",
      "manifest.artifact.name",
      "manifest.artifact_version.prn",
      "manifest.artifact_version.version",
      "bundle.prn",
      "release.prn",
      "release.version",
      "release.version_requirement",
      "bundle_override"
    ])
  end

  # Update to new Release
  defp update_response(
         {:ok, %{status: 200, body: %{"status" => "update", "release" => _release} = body}}
       ) do
    with {:ok, release_metadata} <- Release.metadata_from_manifest(body),
         :ok <- Update.Server.install_bundle(release_metadata) do
      :updating
    end
  end

  defp update_response(
         {:ok,
          %{
            status: 200,
            body: %{"status" => "update", "bundle_override" => _bundle_override} = body
          }}
       ) do
    with {:ok, override_metadata} <- BundleOverride.metadata_from_manifest(body),
         :ok <- Update.Server.install_bundle(override_metadata) do
      :updating
    end
  end

  defp update_response({:ok, %{status: 200, body: %{"status" => "no_update"}}}) do
    Logger.info("[Cloud Server] no update")
    :no_update
  end

  defp update_response({:ok, %{status: 200, body: %{"status" => "device_quarantined"}}}) do
    Logger.info("[Cloud Server] Device Quarantined")
    Logger.info("[Cloud Server] no update")
    :device_quarantined
  end

  defp update_response({_, %{status: status_code, body: body}}) do
    Logger.info("[Cloud Server] Non 200 response from server")
    Logger.info("[Cloud Server] Status code: #{inspect(status_code)}")
    Logger.info("[Cloud Server] Response: #{inspect(body)}")
    {:error, body}
  end

  defp update_response({:error, reason}) do
    Logger.error("[Cloud Server] error checking for update #{inspect(reason)}")
    {:error, reason}
  end
end

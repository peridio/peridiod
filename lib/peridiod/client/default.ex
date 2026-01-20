defmodule Peridiod.Client.Default do
  require Logger

  @behaviour Peridiod.Client

  @impl Peridiod.Client
  def update_available(_update) do
    :apply
  end

  @impl Peridiod.Client
  def handle_fwup_message({:progress, percent}) do
    Logger.info("[Client] Update Progress: #{percent}%")
  end

  def handle_fwup_message({:error, _, message}) do
    Logger.error("[Client] Update Error: #{message}")
  end

  def handle_fwup_message({:warning, _, message}) do
    Logger.warning("[Client] Update Warning: #{message}")
  end

  def handle_fwup_message({:ok, status, message}) do
    Logger.info("[Client] Update Finished: #{status} #{message}")
  end

  def handle_fwup_message(fwup_message) do
    Logger.warning("[Client] Unknown FWUP message: #{inspect(fwup_message)}")
  end

  @impl Peridiod.Client
  def handle_error(error) do
    Logger.warning("[Client] error: #{inspect(error)}")
  end

  @impl Peridiod.Client
  def reboot(opts \\ %{}) do
    # Extract configuration with defaults
    sync_cmd = Map.get(opts, :reboot_sync_cmd, "sync")
    sync_opts = Map.get(opts, :reboot_sync_opts, [])
    reboot_cmd = Map.get(opts, :reboot_cmd, "reboot")
    reboot_opts = Map.get(opts, :reboot_opts, [])

    # Perform sync and reboot (skip in test environment)
    with false <- Peridiod.env_test?(),
         {_sync_output, 0} <- run_sync(sync_cmd, sync_opts),
         :ok <- run_reboot(reboot_cmd, reboot_opts) do
      Logger.warning("[Client] System rebooting now")
    else
      {result, code} ->
        Logger.error(
          "[Client] Exit code #{inspect(code)} while attempting to sync/reboot the system: #{inspect(result)}"
        )

      true ->
        Logger.warning("[Client] Test environment - skipping reboot")
    end
  end

  defp run_sync(sync_cmd, sync_opts) do
    Logger.info("[Client] Running sync command: #{sync_cmd} #{inspect(sync_opts)}")
    {output, status} = System.cmd(sync_cmd, sync_opts, stderr_to_stdout: true)
    Logger.info("[Client] Sync command completed with status: #{status}")
    {output, status}
  end

  defp run_reboot(reboot_cmd, reboot_opts) do
    Logger.warning("[Client] Running reboot command: #{reboot_cmd} #{inspect(reboot_opts)}")
    System.cmd(reboot_cmd, reboot_opts, stderr_to_stdout: true)
    :ok
  end
end

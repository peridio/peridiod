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
  def reboot() do
    # this function must reboot the system
    unless Peridiod.env_test?() do
      Logger.warning("[Client] Rebooting System")
      System.cmd("reboot", [], stderr_to_stdout: true)
    end
  end
end

defmodule Peridiod.Client.Default do
  require Logger

  @behaviour Peridiod.Client

  @impl Peridiod.Client
  def update_available(_update) do
    :apply
  end

  @impl Peridiod.Client
  def handle_fwup_message({:progress, percent}) do
    Logger.debug("[Peridiod] Update Progress: #{percent}%")
  end

  def handle_fwup_message({:error, _, message}) do
    Logger.error("[Peridiod] Update Error: #{message}")
  end

  def handle_fwup_message({:warning, _, message}) do
    Logger.warning("[Peridiod] Update Warning: #{message}")
  end

  def handle_fwup_message({:ok, status, message}) do
    Logger.info("[Peridiod] Update Finished: #{status} #{message}")
  end

  def handle_fwup_message(fwup_message) do
    Logger.warning("Unknown FWUP message: #{inspect(fwup_message)}")
  end

  @impl Peridiod.Client
  def handle_error(error) do
    Logger.warning("[Peridiod] error: #{inspect(error)}")
  end

  @impl Peridiod.Client
  def reboot() do
    # this function must reboot the system
    if Peridiod.env() != :test do
      Logger.warning("[Peridiod] Rebooting System")
      System.cmd("reboot", [], stderr_to_stdout: true)
    end
  end
end

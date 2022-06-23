defmodule PeridioAgent.Link do
  @behaviour NervesHubLink.Client
  require Logger

  @impl NervesHubLink.Client
  def update_available(_update) do
    :apply
  end

  @impl NervesHubLink.Client
  def handle_fwup_message({:progress, percent}) do
    Logger.debug("[Peridio] Update Progress: #{percent}%")
  end

  def handle_fwup_message({:error, _, message}) do
    Logger.error("[Peridio] Update Error: #{message}")
  end

  def handle_fwup_message({:warning, _, message}) do
    Logger.warn("[Peridio] Update Warning: #{message}")
  end

  def handle_fwup_message({:ok, status, message}) do
    Logger.info("[Peridio] Update Finished: #{status} #{message}")
  end

  def handle_fwup_message(fwup_message) do
    Logger.warn("Unknown FWUP message: #{inspect(fwup_message)}")
  end

  @impl NervesHubLink.Client
  def handle_error(error) do
    Logger.warn("[Peridio] error: #{inspect(error)}")
  end

  @impl NervesHubLink.Client
  def reboot() do
    Logger.warn("[Peridio] Rebooting System")
  end
end

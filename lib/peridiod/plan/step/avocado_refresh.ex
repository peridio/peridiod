defmodule Peridiod.Plan.Step.AvocadoRefresh do
  use Peridiod.Plan.Step

  require Logger

  def id(_opts) do
    Module.concat(__MODULE__, UUID.uuid4())
  end

  def init(opts) do
    avocadoctl_cmd = Map.get(opts, :avocadoctl_cmd, "avocadoctl")

    {:ok, %{avocadoctl_cmd: avocadoctl_cmd}}
  end

  def execute(state) do
    Logger.info("[AvocadoRefresh] Refreshing extensions on running system")

    case System.cmd(state.avocadoctl_cmd, ["refresh"], stderr_to_stdout: true) do
      {output, 0} ->
        Logger.info("[AvocadoRefresh] Successfully refreshed extensions")
        Logger.debug("[AvocadoRefresh] Output: #{output}")
        {:stop, :normal, state}

      {output, exit_code} ->
        Logger.error("[AvocadoRefresh] Failed to refresh: #{output}")
        {:error, {:avocado_refresh_failed, exit_code, output}, state}
    end
  end
end

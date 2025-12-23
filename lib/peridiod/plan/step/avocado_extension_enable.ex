defmodule Peridiod.Plan.Step.AvocadoExtensionEnable do
  use Peridiod.Plan.Step

  require Logger

  def id(_opts) do
    Module.concat(__MODULE__, UUID.uuid4())
  end

  def init(%{extension_names: extension_names, os_version: os_version} = opts) do
    avocadoctl_cmd = opts[:avocadoctl_cmd] || "avocadoctl"

    {:ok,
     %{
       extension_names: extension_names,
       os_version: os_version,
       avocadoctl_cmd: avocadoctl_cmd
     }}
  end

  def execute(state) do
    Logger.info("[AvocadoExtensionEnable] Enabling extensions: #{inspect(state.extension_names)}")

    # Build command args
    args = build_enable_args(state.extension_names, state.os_version)

    case System.cmd(state.avocadoctl_cmd, args, stderr_to_stdout: true) do
      {output, 0} ->
        Logger.info("[AvocadoExtensionEnable] Successfully enabled extensions")
        Logger.debug("[AvocadoExtensionEnable] Output: #{output}")
        {:stop, :normal, state}

      {output, exit_code} ->
        Logger.error("[AvocadoExtensionEnable] Failed to enable extensions: #{output}")
        {:error, {:avocado_enable_failed, exit_code, output}, state}
    end
  end

  defp build_enable_args(extension_names, nil) do
    # No OS version, omit --release flag
    ["enable" | extension_names]
  end

  defp build_enable_args(extension_names, os_version) do
    # Include --os-release flag with OS version
    ["enable", "--os-release", os_version | extension_names]
  end
end

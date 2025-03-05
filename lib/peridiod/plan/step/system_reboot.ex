defmodule Peridiod.Plan.Step.SystemReboot do
  use Peridiod.Plan.Step

  require Logger

  def id(_step_opts) do
    Module.concat(__MODULE__, UUID.uuid4())
  end

  def init(%{
        reboot_cmd: reboot_cmd,
        reboot_opts: reboot_opts,
        reboot_delay: reboot_delay,
        reboot_sync_cmd: sync_cmd,
        reboot_sync_opts: sync_opts
      } = opts) do
    {:ok,
     %{
       timer_ref: nil,
       reboot_cmd: reboot_cmd,
       reboot_opts: reboot_opts,
       reboot_delay: reboot_delay,
       sync_cmd: sync_cmd,
       sync_opts: sync_opts,
       callback: opts[:callback]
     }}
  end

  def execute(state) do
    Logger.info("[Step System Reboot] System will reboot in #{trunc(state.reboot_delay/1000)} seconds")
    timer_ref = Process.send_after(self(), :reboot, state.reboot_delay)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  def handle_info(:reboot, state) do
    Logger.info("[Step System Reboot] System rebooting now")
    with false <- Peridiod.env_test?(),
         {_, 0} <-
           System.cmd(state.sync_cmd, state.sync_opts, stderr_to_stdout: true),
         {_, 0} <- System.cmd(state.reboot_cmd, state.reboot_opts, stderr_to_stdout: true) do
      {:stop, :normal, state}
    else
      {result, code} ->
        Logger.error(
          "[Update] Exit code #{inspect(code)} while attempting to reboot the system #{inspect(result)}"
        )

        {:error, result, state}

      true ->
        send(state.callback, :reboot)
        {:stop, :normal, state}
    end
  end
end

defmodule Peridiod.Client do
  @moduledoc """
  A behaviour module for customizing if and when firmware updates get applied.

  By default Peridiod applies updates as soon as it knows about them from the
  Peridiod server and doesn't give warning before rebooting. This let's
  devices hook into the decision making process and monitor the update's
  progress.

  # Example

  ```elixir
  defmodule MyApp.PeridiodClient do
    @behaviour Peridiod.Client

    # May return:
    #  * `:apply` - apply the action immediately
    #  * `:ignore` - don't apply the action, don't ask again.
    #  * `{:reschedule, timeout_in_milliseconds}` - call this function again later.

    @impl Peridiod.Client
    def update_available(data) do
      if SomeInternalAPI.is_now_a_good_time_to_update?(data) do
        :apply
      else
        {:reschedule, 60_000}
      end
    end
  end
  ```

  To have Peridiod invoke it, add the following to your `config.exs`:

  ```elixir
  config :peridiod, client: MyApp.PeridiodClient
  ```
  """

  require Logger

  @typedoc "Update that comes over a socket."
  @type update_data :: Peridiod.Distribution.t()

  @typedoc "Supported responses from `update_available/1`"
  @type update_response :: :apply | :ignore | {:reschedule, pos_integer()}

  @typedoc "Firmware update progress, completion or error report"
  @type fwup_message ::
          {:ok, non_neg_integer(), String.t()}
          | {:warning, non_neg_integer(), String.t()}
          | {:error, non_neg_integer(), String.t()}
          | {:progress, 0..100}

  @doc """
  Called to find out what to do when a firmware update is available.

  May return one of:

  * `apply` - Download and apply the update right now.
  * `ignore` - Don't download and apply this update.
  * `{:reschedule, timeout}` - Defer making a decision. Call this function again in `timeout` milliseconds.
  """
  @callback update_available(update_data()) :: update_response()

  @doc """
  Called on firmware update reports.

  The return value of this function is not checked.
  """
  @callback handle_fwup_message(fwup_message()) :: :ok

  @doc """
  Called when downloading a firmware update fails.

  The return value of this function is not checked.
  """
  @callback handle_error(any()) :: :ok

  @doc """
  Optional callback to reboot the device when a firmware update completes

  The default behavior is to call `reboot` after a successful update. This
  is useful for testing and for doing additional work like notifying users in a UI that a reboot
  will happen soon. It is critical that a reboot does happen.

  The callback accepts an optional map of options with the following keys:
  * `:reboot_cmd` - The system reboot command (default: "reboot")
  * `:reboot_opts` - Extra args to be passed to the reboot command (default: [])
  * `:reboot_sync_cmd` - The system sync command to force filesystem writes (default: "sync")
  * `:reboot_sync_opts` - Extra args to be passed to the sync command (default: [])
  """
  @callback reboot(opts :: map()) :: no_return()

  @optional_callbacks [reboot: 1]

  @doc """
  This function is called internally by Peridiod to notify clients.
  """
  @spec update_available(update_data()) :: update_response()
  def update_available(data) do
    case apply_wrap(mod(), :update_available, [data]) do
      :apply ->
        :apply

      :ignore ->
        :ignore

      {:reschedule, timeout} when timeout > 0 ->
        {:reschedule, timeout}

      wrong ->
        Logger.error(
          "[Client] #{inspect(mod())}.update_available/1 bad return value: #{inspect(wrong)} Applying update."
        )

        :apply
    end
  end

  @doc """
  This function is called internally by Peridiod to notify clients of fwup progress.
  """
  @spec handle_fwup_message(fwup_message()) :: :ok
  def handle_fwup_message(data) do
    _ = apply_wrap(mod(), :handle_fwup_message, [data])

    # TODO: nasty side effects here. Consider moving somewhere else
    case data do
      {:progress, percent} ->
        Peridiod.send_distribution_progress(percent)

      {:error, _, message} ->
        Peridiod.send_distribution_status("fwup error #{message}")

      {:ok, 0, _message} ->
        initiate_reboot()

      _ ->
        :ok
    end
  end

  @doc """
  This function is called internally by Peridiod to initiate a reboot.

  After a successful firmware update, Peridiod calls this to start the
  reboot process. It calls `c:reboot/1` if supplied or
  `:os.cmd('reboot')`.
  """
  @spec initiate_reboot() :: :ok
  def initiate_reboot() do
    client = mod()
    config = Peridiod.config()

    reboot_opts =
      Map.take(config, [
        :reboot_cmd,
        :reboot_opts,
        :reboot_sync_cmd,
        :reboot_sync_opts
      ])

    {mod, fun, args} =
      cond do
        function_exported?(client, :reboot, 1) ->
          {client, :reboot, [reboot_opts]}

        function_exported?(client, :reboot, 0) ->
          {client, :reboot, []}

        true ->
          {:os, :cmd, [~c"reboot"]}
      end

    _ = spawn(mod, fun, args)
    :ok
  end

  @doc """
  This function is called internally by Peridiod to notify clients of fwup errors.
  """
  @spec handle_error(any()) :: :ok
  def handle_error(data) do
    _ = apply_wrap(mod(), :handle_error, [data])
  end

  # Catches exceptions and exits
  defp apply_wrap(mod, function, args) do
    apply(mod, function, args)
  catch
    :error, reason -> {:error, reason}
    :exit, reason -> {:exit, reason}
    err -> err
  end

  defp mod() do
    Application.get_env(:peridiod, :client, Peridiod.Client.Default)
  end
end

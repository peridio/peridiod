defmodule Peridiod.DistributionManager do
  @moduledoc """
  GenServer responsible for brokering messages between:
    * an external controlling process
    * FWUP
    * HTTP

  Should be started in a supervision tree
  """
  use GenServer

  alias Peridiod.{Downloader, Configurator, Client}
  alias Peridiod.Artifact.Adapter.Fwup
  alias Peridiod.Message.DistributionInfo

  require Logger

  defmodule State do
    @moduledoc """
    Structure for the state of the `DistributionManager` server.
    Contains types that describe status and different states the
    `DistributionManager` can be in
    """

    @type status ::
            :idle
            | {:fwup_error, String.t()}
            | :update_rescheduled
            | {:updating, integer()}

    @type t :: %__MODULE__{
            status: status(),
            update_reschedule_timer: nil | :timer.tref(),
            download: nil | GenServer.server(),
            fwup: nil | GenServer.server(),
            fwup_config: Fwup.Config.t(),
            distribution_info: nil | DistributionInfo.t()
          }

    defstruct status: :idle,
              update_reschedule_timer: nil,
              fwup: nil,
              download: nil,
              fwup_config: nil,
              distribution_info: nil
  end

  @doc """
  Must be called when an update payload is dispatched from
  Peridio. the map must contain a `"firmware_url"` key.
  """
  @spec apply_update(GenServer.server(), DistributionInfo.t()) :: State.status()
  def apply_update(manager \\ __MODULE__, %DistributionInfo{} = distribution_info) do
    GenServer.call(manager, {:apply_update, distribution_info})
  end

  @doc """
  Returns the current status of the update manager
  """
  @spec status(GenServer.server()) :: State.status()
  def status(manager \\ __MODULE__) do
    GenServer.call(manager, :status)
  end

  @doc """
  Returns the UUID of the currently downloading firmware, or nil.
  """
  @spec currently_downloading_uuid(GenServer.server()) :: uuid :: String.t() | nil
  def currently_downloading_uuid(manager \\ __MODULE__) do
    GenServer.call(manager, :currently_downloading_uuid)
  end

  @doc """
  Add a FWUP Public key
  """
  @spec add_fwup_public_key(GenServer.server(), String.t()) :: :ok
  def add_fwup_public_key(manager \\ __MODULE__, pubkey) do
    GenServer.call(manager, {:fwup_public_key, :add, pubkey})
  end

  @doc """
  Remove a FWUP public key
  """
  @spec remove_fwup_public_key(GenServer.server(), String.t()) :: :ok
  def remove_fwup_public_key(manager \\ __MODULE__, pubkey) do
    GenServer.call(manager, {:fwup_public_key, :remove, pubkey})
  end

  @doc false
  @spec child_spec(any) :: Supervisor.child_spec()
  def child_spec(args) do
    %{
      start: {__MODULE__, :start_link, [args, [name: __MODULE__]]},
      id: __MODULE__
    }
  end

  @doc false
  @spec start_link(any(), GenServer.options()) :: GenServer.on_start()
  def start_link(_args, opts \\ []) do
    GenServer.start_link(__MODULE__, nil, opts)
  end

  @impl GenServer
  def init(nil) do
    config = Configurator.get_config()

    fwup_config = %Fwup.Config{
      fwup_public_keys: config.fwup_public_keys,
      fwup_devpath: config.fwup_devpath,
      fwup_env: Fwup.Config.parse_fwup_env(config.fwup_env),
      fwup_extra_args: config.fwup_extra_args,
      handle_fwup_message: &Client.handle_fwup_message/1,
      update_available: &Client.update_available/1
    }

    fwup_config = Fwup.Config.validate!(fwup_config)
    {:ok, %State{fwup_config: fwup_config}}
  end

  @impl GenServer
  def handle_call({:apply_update, %DistributionInfo{} = distribution_info}, _from, %State{} = state) do
    state = maybe_update_firmware(distribution_info, state)
    {:reply, state.status, state}
  end

  def handle_call(:currently_downloading_uuid, _from, %State{distribution_info: nil} = state) do
    {:reply, nil, state}
  end

  def handle_call(:currently_downloading_uuid, _from, %State{} = state) do
    {:reply, state.distribution_info.firmware_meta.uuid, state}
  end

  def handle_call(:status, _from, %State{} = state) do
    {:reply, state.status, state}
  end

  def handle_call({:fwup_public_key, action, pubkey}, _from, %State{} = state) do
    pubkey = String.trim(pubkey)
    keys = state.fwup_config.fwup_public_keys

    updated =
      case action do
        :add -> [pubkey | keys]
        :remove -> for i <- keys, i != pubkey, do: i
      end

    state = put_in(state.fwup_config.fwup_public_keys, Enum.uniq(updated))
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info({:update_reschedule, response}, state) do
    {:noreply, maybe_update_firmware(response, %State{state | update_reschedule_timer: nil})}
  end

  # messages from FWUP
  def handle_info({:fwup, message}, state) do
    _ = state.fwup_config.handle_fwup_message.(message)

    case message do
      {:ok, 0, _message} ->
        Logger.info("[Peridiod] FWUP Finished")
        {:noreply, %State{state | fwup: nil, distribution_info: nil, status: :idle}}

      {:progress, percent} ->
        {:noreply, %State{state | status: {:updating, percent}}}

      {:error, _, message} ->
        {:noreply, %State{state | status: {:fwup_error, message}}}

      _ ->
        {:noreply, state}
    end
  end

  # messages from Downloader
  def handle_info({:download, :complete}, state) do
    Logger.info("[Peridiod] Firmware Download complete")
    {:noreply, %State{state | download: nil}}
  end

  def handle_info({:download, {:error, reason}}, state) do
    Logger.error("[Peridiod] Nonfatal HTTP download error: #{inspect(reason)}")
    {:noreply, state}
  end

  # Data from the downloader is sent to fwup
  def handle_info({:download, {:data, data}}, state) do
    _ = Fwup.Stream.send_chunk(state.fwup, data)
    {:noreply, state}
  end

  @spec maybe_update_firmware(DistributionInfo.t(), State.t()) :: State.t()
  defp maybe_update_firmware(
         %DistributionInfo{} = _distribution_info,
         %State{status: {:updating, _percent}} = state
       ) do
    # Received an update message from Peridio, but we're already in progress.
    # It could be because the deployment/device was edited making a duplicate
    # update message or a new deployment was created. Either way, lets not
    # interrupt FWUP and let the task finish. After update and reboot, the
    # device will check-in and get an update message if it was actually new and
    # required
    state
  end

  defp maybe_update_firmware(%DistributionInfo{} = distribution_info, %State{} = state) do
    # Cancel an existing timer if it exists.
    # This prevents rescheduled updates`
    # from compounding.
    state = maybe_cancel_timer(state)

    # possibly offload update decision to an external module.
    # This will allow application developers
    # to control exactly when an update is applied.
    # note: update_available is a behaviour function
    case state.fwup_config.update_available.(distribution_info) do
      :apply ->
        start_fwup_stream(distribution_info, state)

      :ignore ->
        state

      {:reschedule, ms} ->
        timer = Process.send_after(self(), {:update_reschedule, distribution_info}, ms)
        Logger.info("[Peridiod] rescheduling firmware update in #{ms} milliseconds")
        %{state | status: :update_rescheduled, update_reschedule_timer: timer}
    end
  end

  defp maybe_update_firmware(_, state), do: state

  defp maybe_cancel_timer(%{update_reschedule_timer: nil} = state), do: state

  defp maybe_cancel_timer(%{update_reschedule_timer: timer} = state) do
    _ = Process.cancel_timer(timer)

    %{state | update_reschedule_timer: nil}
  end

  @spec start_fwup_stream(DistributionInfo.t(), State.t()) :: State.t()
  defp start_fwup_stream(%DistributionInfo{} = distribution_info, state) do
    pid = self()
    fun = &send(pid, {:download, &1})
    {:ok, download} = Downloader.start_download(distribution_info.firmware_url, fun)

    {:ok, fwup} =
      Fwup.stream(pid, fwup_args(state.fwup_config), fwup_env: state.fwup_config.fwup_env)

    Logger.info("[Peridiod] Downloading firmware: #{distribution_info.firmware_url}")

    %State{
      state
      | status: {:updating, 0},
        download: download,
        fwup: fwup,
        distribution_info: distribution_info
    }
  end

  @spec fwup_args(Fwup.Config.t()) :: [String.t()]
  defp fwup_args(%Fwup.Config{} = config) do
    args =
      [
        "--apply",
        "--no-unmount",
        "-d",
        config.fwup_devpath,
        "--task",
        config.fwup_task
      ] ++ config.fwup_extra_args

    Enum.reduce(config.fwup_public_keys, args, fn public_key, args ->
      args ++ ["--public-key", public_key]
    end)
  end
end

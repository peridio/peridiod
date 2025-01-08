defmodule Peridiod.Distribution.Server do
  @moduledoc """
  GenServer responsible for brokering messages between:
    * an external controlling process
    * FWUP
    * HTTP

  Should be started in a supervision tree
  """
  use GenServer

  alias Peridiod.{Client, Distribution}
  alias Peridiod.Binary.{StreamDownloader, StreamDownloader.Supervisor, Installer.Fwup}
  alias PeridiodPersistence.KV

  require Logger

  defmodule State do
    @moduledoc """
    Structure for the state of the `Distribution.Server`.
    Contains types that describe status and different states the
    `Distribution.Server` can be in
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
            distribution: nil | Distribution.t(),
            callback: pid()
          }

    defstruct status: :idle,
              update_reschedule_timer: nil,
              fwup: nil,
              download: nil,
              fwup_config: nil,
              distribution: nil,
              callback: nil
  end

  @doc """
  Must be called when an update payload is dispatched from
  Peridio. the map must contain a `"firmware_url"` key.
  """
  @spec apply_update(GenServer.server(), Distribution.t()) :: State.status()
  def apply_update(pid_or_name \\ __MODULE__, %Distribution{} = distribution) do
    GenServer.call(pid_or_name, {:apply_update, distribution})
  end

  @doc """
  Returns the current status of the update server
  """
  @spec status(GenServer.server()) :: State.status()
  def status(pid_or_name \\ __MODULE__) do
    GenServer.call(pid_or_name, :status)
  end

  @doc """
  Returns the UUID of the currently downloading firmware, or nil.
  """
  @spec currently_downloading_uuid(GenServer.server()) :: uuid :: String.t() | nil
  def currently_downloading_uuid(pid_or_name \\ __MODULE__) do
    GenServer.call(pid_or_name, :currently_downloading_uuid)
  end

  @doc """
  Add a FWUP Public key
  """
  @spec add_fwup_public_key(GenServer.server(), String.t()) :: :ok
  def add_fwup_public_key(pid_or_name \\ __MODULE__, pubkey) do
    GenServer.call(pid_or_name, {:fwup_public_key, :add, pubkey})
  end

  @doc """
  Remove a FWUP public key
  """
  @spec remove_fwup_public_key(GenServer.server(), String.t()) :: :ok
  def remove_fwup_public_key(pid_or_name \\ __MODULE__, pubkey) do
    GenServer.call(pid_or_name, {:fwup_public_key, :remove, pubkey})
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
  def start_link(config, opts \\ []) do
    GenServer.start_link(__MODULE__, config, opts)
  end

  @impl GenServer
  def init(config) do
    fwup_devpath =
      config.fwup_devpath || KV.get("peridio_disk_devpath") ||
        KV.get("nerves_fw_devpath")

    fwup_config = %Fwup.Config{
      fwup_public_keys: config.fwup_public_keys,
      fwup_devpath: fwup_devpath,
      fwup_env: Fwup.Config.parse_fwup_env(config.fwup_env),
      fwup_extra_args: config.fwup_extra_args,
      handle_fwup_message: &Client.handle_fwup_message/1,
      update_available: &Client.update_available/1
    }

    fwup_config =
      fwup_config
      |> Fwup.Config.validate_base!()
      |> Fwup.Config.validate_callbacks!()

    Process.flag(:trap_exit, true)

    {:ok, %State{fwup_config: fwup_config}}
  end

  @impl GenServer
  def handle_call(
        {:apply_update, %Distribution{} = distribution},
        {from, _ref},
        %State{} = state
      ) do
    state = maybe_update_firmware(distribution, state)
    {:reply, state.status, %{state | callback: from}}
  end

  def handle_call(:currently_downloading_uuid, _from, %State{distribution: nil} = state) do
    {:reply, nil, state}
  end

  def handle_call(:currently_downloading_uuid, _from, %State{} = state) do
    {:reply, state.distribution.firmware_meta.uuid, state}
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
        try_send(state.callback, {__MODULE__, :install, :complete})
        {:noreply, %State{state | fwup: nil, distribution: nil, status: :idle}}

      {:progress, percent} ->
        try_send(state.callback, {__MODULE__, :install, {:percent, percent}})
        {:noreply, %State{state | status: {:updating, percent}}}

      {:error, _, message} ->
        try_send(state.callback, {__MODULE__, :install, {:error, message}})
        {:noreply, %State{state | status: {:fwup_error, message}}}

      _ ->
        {:noreply, state}
    end
  end

  # messages from Download
  def handle_info({:download, :complete}, state) do
    Logger.info("[Peridiod] Firmware Download complete")
    {:noreply, %State{state | download: nil}}
  end

  def handle_info({:download, {:error, reason}}, state) do
    Logger.error("[Peridiod] Nonfatal HTTP download error: #{inspect(reason)}")
    {:noreply, state}
  end

  # Data from the download is sent to fwup
  def handle_info({:download, {:data, data}}, state) do
    _ = Fwup.Stream.send_chunk(state.fwup, data)
    {:noreply, state}
  end

  def handle_info({:EXIT, _, error}, state) do
    try_send(state.callback, {__MODULE__, :install, {:error, error}})
    {:noreply, state}
  end

  @spec maybe_update_firmware(Distribution.t(), State.t()) :: State.t()
  defp maybe_update_firmware(
         %Distribution{} = _distribution,
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

  defp maybe_update_firmware(%Distribution{} = distribution, %State{} = state) do
    # Cancel an existing timer if it exists.
    # This prevents rescheduled updates`
    # from compounding.
    state = maybe_cancel_timer(state)

    # possibly offload update decision to an external module.
    # This will allow application developers
    # to control exactly when an update is applied.
    # note: update_available is a behaviour function
    case state.fwup_config.update_available.(distribution) do
      :apply ->
        start_fwup_stream(distribution, state)

      :ignore ->
        state

      {:reschedule, ms} ->
        timer = Process.send_after(self(), {:update_reschedule, distribution}, ms)
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

  @spec start_fwup_stream(Distribution.t(), State.t()) :: State.t()
  defp start_fwup_stream(%Distribution{} = distribution, state) do
    pid = self()
    fun = &send(pid, {:download, &1})

    {:ok, download} =
      StreamDownloader.Supervisor.start_child(
        distribution.firmware_meta.uuid,
        distribution.firmware_url,
        fun
      )

    {:ok, fwup} =
      Fwup.stream(pid, Fwup.Config.to_cmd_args(state.fwup_config),
        fwup_env: state.fwup_config.fwup_env
      )

    Logger.info("[Peridiod] Downloading firmware: #{distribution.firmware_url}")

    %State{
      state
      | status: {:updating, 0},
        download: download,
        fwup: fwup,
        distribution: distribution
    }
  end

  defp try_send(nil, _msg), do: :ok

  defp try_send(pid, msg) do
    if Process.alive?(pid) do
      send(pid, msg)
    end
  end
end

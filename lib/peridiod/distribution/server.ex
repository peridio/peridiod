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
  alias Peridiod.Binary.{Downloader, Downloader.Supervisor, Installer.Fwup}
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
            callback: pid(),
            cache_dir: String.t(),
            download_before_fwup: boolean(),
            download_file_path: nil | String.t()
          }

    defstruct status: :idle,
              update_reschedule_timer: nil,
              fwup: nil,
              download: nil,
              fwup_config: nil,
              distribution: nil,
              callback: nil,
              cache_dir: "/tmp",
              download_before_fwup: false,
              download_file_path: nil
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

    Logger.info(
      "[Distributions] Download before FWUP config: '#{config.download_before_fwup}', cache_dir: '#{config.cache_dir}'"
    )

    {:ok,
     %State{
       fwup_config: fwup_config,
       cache_dir: config.cache_dir,
       download_before_fwup: config.download_before_fwup
     }}
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
        Logger.info("[Distributions] FWUP Finished")
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
    # Gather download information for debugging
    firmware_uuid = state.distribution && state.distribution.firmware_meta.uuid
    firmware_url = state.distribution && state.distribution.firmware_url
    downloaded_bytes = if state.download, do: get_download_info(state.download), else: %{}

    # Get file information if we cached the file
    file_info =
      if state.download_before_fwup && state.download_file_path do
        get_file_info(state.download_file_path)
      else
        %{}
      end

    Logger.info("[Distributions] Firmware Download complete")
    Logger.info("[Distributions] Download Details:")
    Logger.info("  - UUID: #{firmware_uuid}")
    Logger.info("  - URL: #{firmware_url}")

    Logger.info(
      "  - Downloaded bytes: #{Map.get(downloaded_bytes, :downloaded_length, "unknown")}"
    )

    Logger.info("  - Content length: #{Map.get(downloaded_bytes, :content_length, "unknown")}")
    Logger.info("  - Status: #{Map.get(downloaded_bytes, :status, "unknown")}")

    if state.download_before_fwup do
      Logger.info("  - Cached file path: #{state.download_file_path || "not set"}")
      Logger.info("  - File size: #{Map.get(file_info, :size, "unknown")} bytes")
      Logger.info("  - SHA256 hash: #{Map.get(file_info, :hash, "not calculated")}")
      Logger.info("  - Note: File cached to disk before fwup processing")
    else
      Logger.info("  - Note: File was streamed directly to fwup (no disk cache)")
    end

    {:noreply, %State{state | download: nil, download_file_path: nil}}
  end

  def handle_info({:download, {:error, reason}}, state) do
    Logger.error("[Distributions] Nonfatal HTTP download error: #{inspect(reason)}")
    {:noreply, state}
  end

  # Data from the download is sent to fwup
  def handle_info({:download, {:stream, data}}, state) do
    data_size = byte_size(data)
    firmware_uuid = state.distribution && state.distribution.firmware_meta.uuid
    firmware_url = state.distribution && state.distribution.firmware_url

    updated_state =
      if state.download_before_fwup do
        # Initialize file path on first chunk if not already set
        file_path =
          state.download_file_path || get_download_file_path(state.cache_dir, firmware_uuid)

        # Ensure directory exists and write data to file
        case ensure_download_dir(file_path) do
          :ok ->
            case File.write(file_path, data, [:append, :binary]) do
              :ok ->
                # Logger.info(
                #   "[Distributions] Cached download data - Size: #{data_size} bytes, File: #{file_path}, UUID: #{firmware_uuid}, URL: #{firmware_url}"
                # )
                IO.write(".")

                %{state | download_file_path: file_path}

              {:error, reason} ->
                Logger.error("[Distributions] Failed to cache download data: #{inspect(reason)}")
                state
            end

          {:error, reason} ->
            Logger.error(
              "[Distributions] Failed to create download directory: #{inspect(reason)}"
            )

            state
        end
      else
        # Original logic without file caching
        Logger.info(
          "[Distributions] Received download data - Size: #{data_size} bytes, UUID: #{firmware_uuid}, URL: #{firmware_url}"
        )

        # Temporarily commenting out fwup sending for download resumption testing
        # _ = Fwup.Stream.send_chunk(state.fwup, data)

        state
      end

    {:noreply, updated_state}
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
        Logger.info("[Distributions] rescheduling firmware update in #{ms} milliseconds")
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
    firmware_uuid = distribution.firmware_meta.uuid

    # Set status to updating immediately to prevent concurrent downloads
    state = %{state | status: {:updating, 0}, distribution: distribution}

    # Check for existing cached file and prepare for potential resume
    {download_state, file_path} =
      if state.download_before_fwup do
        prepare_download_with_cache(state.cache_dir, firmware_uuid, distribution.firmware_url)
      else
        {:new_download, nil}
      end

    {:ok, download} =
      case download_state do
        {:resume_download, existing_size} ->
          Logger.info(
            "[Distributions] Found existing cached file (#{existing_size} bytes), attempting to resume download"
          )

          start_child_with_resume(firmware_uuid, distribution.firmware_url, fun, existing_size)

        :new_download ->
          Logger.info("[Distributions] Starting new download")
          Downloader.Supervisor.start_child(firmware_uuid, distribution.firmware_url, fun)
      end

    {:ok, fwup} =
      Fwup.stream(pid, Fwup.Config.to_cmd_args(state.fwup_config),
        fwup_env: state.fwup_config.fwup_env
      )

    Logger.info("[Distributions] Downloading firmware: #{distribution.firmware_url}")

    %State{
      state
      | download: download,
        fwup: fwup,
        download_file_path: file_path
    }
  end

  defp get_download_info(download_pid) when is_pid(download_pid) do
    try do
      case :sys.get_state(download_pid) do
        %{downloaded_length: dl, content_length: cl, status: status, uri: uri} ->
          %{
            downloaded_length: dl,
            content_length: cl,
            status: status,
            uri: uri
          }

        _ ->
          %{}
      end
    catch
      :exit, _ -> %{}
    end
  end

  defp get_download_info(_), do: %{}

  defp get_download_file_path(cache_dir, firmware_uuid) do
    # Follow existing cache conventions: cache_dir/downloads/firmware_uuid/firmware.bin
    downloads_dir = Path.join(cache_dir, "downloads")
    firmware_dir = Path.join(downloads_dir, firmware_uuid)
    Path.join(firmware_dir, "firmware.bin")
  end

  defp ensure_download_dir(file_path) do
    file_path
    |> Path.dirname()
    |> File.mkdir_p()
  end

  defp get_file_info(file_path) when is_binary(file_path) do
    try do
      case File.stat(file_path) do
        {:ok, %File.Stat{size: size}} ->
          # Calculate SHA256 hash of the file
          hash =
            case File.read(file_path) do
              {:ok, content} ->
                :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

              _ ->
                "error reading file"
            end

          %{size: size, hash: hash}

        {:error, _reason} ->
          %{size: "file not found", hash: "file not found"}
      end
    rescue
      _ -> %{size: "error", hash: "error"}
    end
  end

  defp get_file_info(_), do: %{size: "invalid path", hash: "invalid path"}

  defp prepare_download_with_cache(cache_dir, firmware_uuid, _firmware_url) do
    file_path = get_download_file_path(cache_dir, firmware_uuid)

    case File.stat(file_path) do
      {:ok, %File.Stat{size: size}} when size > 0 ->
        Logger.info("[Distributions] Found existing cached file: #{file_path} (#{size} bytes)")
        {{:resume_download, size}, file_path}

      {:ok, %File.Stat{size: 0}} ->
        Logger.info("[Distributions] Found empty cached file, removing and starting fresh")
        File.rm(file_path)
        {:new_download, file_path}

      {:error, :enoent} ->
        Logger.info("[Distributions] No existing cached file found, starting new download")
        {:new_download, file_path}

      {:error, reason} ->
        Logger.warning(
          "[Distributions] Error checking cached file: #{inspect(reason)}, starting new download"
        )

        {:new_download, file_path}
    end
  end

  defp start_child_with_resume(id, url, fun, existing_size) do
    # We need to create a custom child spec that initializes the downloader with existing progress
    alias Peridiod.Binary.Downloader.RetryConfig

    child_spec = %{
      id: Module.concat(Peridiod.Binary.Downloader, id),
      start:
        {Peridiod.Binary.Downloader, :start_link_with_resume,
         [id, URI.parse(url), fun, %RetryConfig{}, existing_size]},
      shutdown: 5000,
      type: :worker,
      restart: :transient
    }

    DynamicSupervisor.start_child(Peridiod.Binary.Downloader.Supervisor, child_spec)
  end

  defp try_send(nil, _msg), do: :ok

  defp try_send(pid, msg) do
    if Process.alive?(pid) do
      send(pid, msg)
    end
  end
end

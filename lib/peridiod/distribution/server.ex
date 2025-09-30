defmodule Peridiod.Distribution.Server do
  @moduledoc """
  GenServer responsible for brokering messages between:
    * an external controlling process
    * FWUP
    * HTTP

  Should be started in a supervision tree
  """
  use GenServer

  alias Peridiod.{Client, Distribution, Cache}

  alias Peridiod.Binary.{
    Downloader,
    ParallelDownloader,
    Downloader.RetryConfig,
    Downloader.Supervisor,
    Installer.Fwup
  }

  alias Peridiod.Distribution.DownloadCache
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
            distributions_cache_download: boolean(),
            download_file_path: nil | String.t(),
            config: Peridiod.Config.t(),
            async_streaming:
              nil
              | %{file_path: String.t(), offset: non_neg_integer(), file_size: non_neg_integer()},
            pending_download_plan: nil | any()
          }

    defstruct status: :idle,
              update_reschedule_timer: nil,
              fwup: nil,
              download: nil,
              fwup_config: nil,
              distribution: nil,
              callback: nil,
              distributions_cache_download: false,
              download_file_path: nil,
              next_chunk_to_stream: nil,
              ready_chunk_files: %{},
              total_chunks: nil,
              config: nil,
              async_streaming: nil,
              pending_download_plan: nil
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

    {:ok,
     %State{
       fwup_config: fwup_config,
       distributions_cache_download: config.distributions_cache_download,
       config: config
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
    if state.distributions_cache_download do
      handle_cached_download_complete(state)
    else
      handle_streamed_download_complete(state)
    end
  end

  def handle_info({:download, {:error, reason}}, state) do
    Logger.error("[Distributions] Nonfatal HTTP download error: #{inspect(reason)}")
    {:noreply, state}
  end

  # Handle parallel download progress (silently track progress)
  def handle_info({:download, {:progress, _progress_info}}, state) do
    # Progress tracking without logging to reduce noise
    {:noreply, state}
  end

  # Handle parallel chunk completion: stream in-order to fwup
  def handle_info({:download, {:chunk_complete, chunk_number, rel_path}}, %State{} = state) do
    Logger.info("[Distributions] Chunk ##{chunk_number} completed: #{Path.basename(rel_path)}")

    state =
      if is_map(state.ready_chunk_files) do
        %{state | ready_chunk_files: Map.put(state.ready_chunk_files, chunk_number, rel_path)}
      else
        %{state | ready_chunk_files: %{chunk_number => rel_path}}
      end

    Logger.debug(
      "[Distributions] Ready chunks: #{inspect(Map.keys(state.ready_chunk_files))}, next to stream: #{state.next_chunk_to_stream}"
    )

    {:noreply, stream_ready_chunks_in_order(state)}
  end

  # Data from the download is sent to fwup
  def handle_info({:download, {:stream, data}}, state) do
    updated_state =
      if state.distributions_cache_download do
        # Write to cache .part and stream to FWUP
        rel_path = state.download_file_path

        case Cache.write_stream_update(state.config.cache_pid, rel_path, data) do
          :ok ->
            _ = if state.fwup, do: Fwup.Stream.send_chunk(state.fwup, data)
            state

          {:error, reason} ->
            Logger.error("[Distributions] Failed to cache download data: #{inspect(reason)}")
            state
        end
      else
        # Stream download data directly to fwup
        _ = if state.fwup, do: Fwup.Stream.send_chunk(state.fwup, data)
        state
      end

    {:noreply, updated_state}
  end

  def handle_info({:EXIT, _, error}, state) do
    try_send(state.callback, {__MODULE__, :install, {:error, error}})
    {:noreply, state}
  end

  def handle_info({:async_stream_small_chunk_file, file_path}, %State{} = state) do
    try do
      case File.read(file_path) do
        {:ok, data} ->
          if state.fwup do
            try do
              :ok = Fwup.Stream.send_chunk(state.fwup, data, 2000)

              Logger.debug(
                "[Distributions] Small chunk streamed successfully: #{Path.basename(file_path)}"
              )

              # Small chunk complete, continue with next chunk in sequence
              {:noreply, stream_ready_chunks_in_order(state)}
            rescue
              e ->
                Logger.error("[Distributions] Failed to send small chunk to FWUP: #{inspect(e)}")

                state = %{
                  state
                  | status: {:fwup_error, "Small chunk streaming failed: #{inspect(e)}"}
                }

                {:noreply, state}
            end
          else
            Logger.error(
              "[Distributions] FWUP process not available during small chunk streaming"
            )

            state = %{state | status: {:fwup_error, "FWUP process not available"}}
            {:noreply, state}
          end

        {:error, reason} ->
          Logger.error("[Distributions] Failed to read small chunk file: #{inspect(reason)}")
          state = %{state | status: {:fwup_error, "Small chunk read failed: #{inspect(reason)}"}}
          {:noreply, state}
      end
    rescue
      e ->
        Logger.error("[Distributions] Exception during small chunk streaming: #{inspect(e)}")
        state = %{state | status: {:fwup_error, "Small chunk streaming exception: #{inspect(e)}"}}
        {:noreply, state}
    end
  end

  def handle_info({:async_stream_file, file_path, offset}, %State{} = state) do
    case state.async_streaming do
      %{file_path: ^file_path, file_size: file_size} when offset >= file_size ->
        # Streaming complete for this large chunk
        Logger.info(
          "[Distributions] Async streaming complete for large chunk: #{Path.basename(file_path)}"
        )

        # Clear async streaming state and continue with next chunk in sequence or pending download
        state_cleared = %{state | async_streaming: nil}

        # Check if we need to continue with pending download plan or stream next chunk
        case state.pending_download_plan do
          nil ->
            # No pending download, check if we need to stream the next chunk
            {:noreply, stream_ready_chunks_in_order(state_cleared)}

          {plan, distribution, handler_fun} ->
            download =
              execute_cached_download_plan(plan, distribution, state_cleared, handler_fun)

            {:noreply, %{state_cleared | download: download, pending_download_plan: nil}}
        end

      %{file_path: ^file_path} ->
        # Continue streaming this file
        handle_async_stream_chunk(file_path, offset, state)

      _ ->
        # Different file or invalid state - this should not happen with proper ordering
        Logger.warning(
          "[Distributions] Async stream chunk for unexpected file: #{file_path}, expected: #{inspect(state.async_streaming)}"
        )

        {:noreply, state}
    end
  end

  def handle_info({:async_stream_file, _file_path, _offset}, %State{async_streaming: nil} = state) do
    # Streaming was cancelled or completed, ignore
    Logger.debug("[Distributions] Ignoring async stream chunk for cancelled streaming")
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
    Logger.info("[Distributions] Received update message but already updating, ignoring")
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
        do_apply_firmware(distribution, state)

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

  @spec do_apply_firmware(Distribution.t(), State.t()) :: State.t()
  defp do_apply_firmware(
         %Distribution{} = distribution,
         %{distributions_cache_download: true} = state
       ) do
    handler_fun = download_handler_fun()
    firmware_uuid = distribution.firmware_meta.uuid
    firmware_url = distribution.firmware_url
    state = %{state | status: {:updating, 0}, distribution: distribution}

    Logger.info(
      "[Distributions] Downloading firmware to disk cache (with live FWUP stream): #{firmware_url}"
    )

    :ok = cleanup_download_cache(state.config.cache_pid, firmware_uuid)
    {plan, file_path} = plan_cached_download(distribution, state)

    case plan do
      :complete ->
        # File already fully cached; apply directly via fwup using the existing file
        final_abs_path = Cache.abs_path(state.config.cache_pid, file_path)

        Logger.info("[Distributions] Cached file present, applying via FWUP: #{final_abs_path}")

        case Fwup.apply(
               state.fwup_config.fwup_devpath,
               state.fwup_config.fwup_task,
               final_abs_path,
               state.fwup_config.fwup_extra_args
             ) do
          {:ok, fwup_pid} ->
            %State{state | fwup: fwup_pid, download_file_path: file_path}

          {:error, reason} ->
            Logger.error(
              "[Distributions] Failed to start fwup for cached file: #{inspect(reason)}"
            )

            %State{
              state
              | status: {:fwup_error, "Failed to apply cached firmware: #{inspect(reason)}"}
            }
        end

      _ ->
        # Start FWUP streaming session up front to provide progress throughout download
        {:ok, fwup} =
          Fwup.stream(self(), Fwup.Config.to_cmd_args(state.fwup_config),
            fwup_env: state.fwup_config.fwup_env
          )

        # Initialize state for parallel downloads if needed
        {next_chunk, total_chunks} =
          case plan do
            {:parallel, total_size, _final_rel_path} ->
              # Calculate number of chunks for parallel downloads
              chunk_size = state.config.distributions_download_parallel_chunk_bytes

              num_chunks =
                div(total_size, chunk_size) + if rem(total_size, chunk_size) > 0, do: 1, else: 0

              Logger.info(
                "[Distributions] Initialized parallel streaming: expecting #{num_chunks} chunks, starting from chunk #0"
              )

              {0, num_chunks}

            _ ->
              {nil, nil}
          end

        state_with_fwup =
          %State{
            state
            | fwup: fwup,
              download_file_path: file_path,
              next_chunk_to_stream: next_chunk,
              ready_chunk_files: %{},
              total_chunks: total_chunks
          }

        # Check if we need pre-streaming and handle accordingly
        case plan do
          {:non_parallel_resume, _existing_size} ->
            # Start async pre-streaming and store the download plan to execute after completion
            state_with_prestream = pre_stream_existing_if_needed(plan, state_with_fwup)

            %State{
              state_with_prestream
              | pending_download_plan: {plan, distribution, handler_fun}
            }

          _ ->
            # No pre-streaming needed, start download immediately
            download =
              execute_cached_download_plan(plan, distribution, state_with_fwup, handler_fun)

            %State{state_with_fwup | download: download}
        end
    end
  end

  @spec do_apply_firmware(Distribution.t(), State.t()) :: State.t()
  defp do_apply_firmware(%Distribution{} = distribution, state) do
    handler_fun = download_handler_fun()
    firmware_uuid = distribution.firmware_meta.uuid
    firmware_url = distribution.firmware_url

    Logger.info("[Distributions] Downloading and streaming firmware to fwup: #{firmware_url}")

    {:ok, download} = start_downloader(firmware_uuid, firmware_url, handler_fun)

    {:ok, fwup} =
      Fwup.stream(self(), Fwup.Config.to_cmd_args(state.fwup_config),
        fwup_env: state.fwup_config.fwup_env
      )

    Logger.info("[Distributions] Downloading firmware: #{firmware_url}")

    %State{
      state
      | status: {:updating, 0},
        download: download,
        fwup: fwup,
        distribution: distribution
    }
  end

  defp rename_completed_download(state, firmware_uuid) do
    # Only rename if the current relative path ends with .part
    current_rel = state.download_file_path

    if is_binary(current_rel) and String.ends_with?(current_rel, ".part") do
      final_rel = DownloadCache.cache_file(%{uuid: firmware_uuid})
      current_abs = Cache.abs_path(state.config.cache_pid, current_rel)
      final_abs = Cache.abs_path(state.config.cache_pid, final_rel)

      case File.rename(current_abs, final_abs) do
        :ok ->
          Logger.info(
            "[Distributions] Renamed completed download from #{current_abs} to #{final_abs}"
          )

          final_rel

        {:error, reason} ->
          Logger.error("[Distributions] Failed to rename completed download: #{inspect(reason)}")
          # Return the original path if rename fails
          current_rel
      end
    else
      # File doesn't end with .part, return as-is
      current_rel
    end
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

  defp start_downloader(firmware_uuid, firmware_url, updater_fun) do
    Downloader.Supervisor.start_child(firmware_uuid, firmware_url, updater_fun)
  end

  defp start_downloader_with_resume(firmware_uuid, firmware_url, updater_fun, existing_size) do
    child_spec = %{
      id: Module.concat(Downloader, firmware_uuid),
      start:
        {Downloader, :start_link_with_resume,
         [firmware_uuid, URI.parse(firmware_url), updater_fun, %RetryConfig{}, existing_size]},
      shutdown: 5000,
      type: :worker,
      restart: :transient
    }

    DynamicSupervisor.start_child(Downloader.Supervisor, child_spec)
  end

  defp start_parallel_downloader(
         firmware_uuid,
         distribution_url,
         handler_fun,
         total_size,
         config,
         _final_rel_path
       ) do
    parallel_downloader_spec =
      ParallelDownloader.child_spec(
        firmware_uuid,
        distribution_url,
        total_size,
        config.distributions_download_parallel_chunk_bytes,
        config.distributions_download_parallel_count,
        DownloadCache.cache_file(%{uuid: firmware_uuid}),
        config.cache_pid,
        handler_fun,
        %RetryConfig{}
      )

    DynamicSupervisor.start_child(Downloader.Supervisor, parallel_downloader_spec)
  end

  defp plan_cached_download(%Distribution{} = distribution, %State{} = state) do
    firmware_uuid = distribution.firmware_meta.uuid
    final_rel_path = DownloadCache.cache_file(%{uuid: firmware_uuid})
    part_rel_path = DownloadCache.part_file(firmware_uuid)

    case File.stat(Cache.abs_path(state.config.cache_pid, final_rel_path)) do
      {:ok, %File.Stat{size: size}} when size > 0 ->
        Logger.info(
          "[Distributions] Found completed cached download: #{Cache.abs_path(state.config.cache_pid, final_rel_path)} (#{size} bytes)"
        )

        {:complete, final_rel_path}

      _ ->
        if should_use_parallel_download?(state) do
          case get_content_length(distribution.firmware_url) do
            total_file_size when is_integer(total_file_size) and total_file_size > 0 ->
              Logger.info(
                "[Distributions] Starting parallel download: #{total_file_size} bytes in #{state.config.distributions_download_parallel_chunk_bytes} byte chunks"
              )

              {{:parallel, total_file_size, final_rel_path}, final_rel_path}

            _ ->
              Logger.warning(
                "[Distributions] Cannot use parallel download without file size, falling back to single download"
              )

              plan_non_parallel_download(state, part_rel_path)
          end
        else
          plan_non_parallel_download(state, part_rel_path)
        end
    end
  end

  defp plan_non_parallel_download(%State{} = state, part_rel_path) do
    case File.stat(Cache.abs_path(state.config.cache_pid, part_rel_path)) do
      {:ok, %File.Stat{size: size}} when size > 0 ->
        Logger.info(
          "[Distributions] Found incomplete cached file: #{Cache.abs_path(state.config.cache_pid, part_rel_path)} (#{size} bytes), resuming download"
        )

        {{:non_parallel_resume, size}, part_rel_path}

      {:ok, %File.Stat{size: 0}} ->
        Logger.info("[Distributions] Found empty cached file, removing and starting fresh")

        File.rm(Cache.abs_path(state.config.cache_pid, part_rel_path))
        {:non_parallel_fresh, part_rel_path}

      {:error, :enoent} ->
        Logger.info("[Distributions] No existing cached file found, starting new download")

        {:non_parallel_fresh, part_rel_path}

      {:error, reason} ->
        Logger.warning(
          "[Distributions] Error checking cached file: #{inspect(reason)}, starting new download"
        )

        {:non_parallel_fresh, part_rel_path}
    end
  end

  defp should_use_parallel_download?(%State{} = state) do
    state.config.distributions_download_parallel_count > 1
  end

  # Executes a previously chosen plan. Returns the download pid or nil.
  defp execute_cached_download_plan(plan, distribution, state, handler_fun) do
    firmware_uuid = distribution.firmware_meta.uuid
    firmware_url = distribution.firmware_url

    case plan do
      :complete ->
        Logger.info("[Distributions] Download already complete")
        send(self(), {:download, :complete})
        nil

      {:non_parallel_resume, existing_size} ->
        Logger.info(
          "[Distributions] Found existing cached file (#{existing_size} bytes), attempting to resume non-parallel download"
        )

        {:ok, download} =
          start_downloader_with_resume(firmware_uuid, firmware_url, handler_fun, existing_size)

        download

      :non_parallel_fresh ->
        Logger.info("[Distributions] Starting new non-parallel download")
        {:ok, download} = start_downloader(firmware_uuid, firmware_url, handler_fun)
        download

      {:parallel, total_size, final_rel_path} ->
        Logger.info(
          "[Distributions] Starting parallel file download: #{firmware_url} (#{total_size} bytes) with #{state.config.distributions_download_parallel_count} parallel connections, #{state.config.distributions_download_parallel_chunk_bytes} bytes per chunk"
        )

        {:ok, download} =
          start_parallel_downloader(
            firmware_uuid,
            firmware_url,
            handler_fun,
            total_size,
            state.config,
            final_rel_path
          )

        download
    end
  end

  defp download_handler_fun() do
    pid = self()
    &send(pid, {:download, &1})
  end

  defp get_content_length(url) do
    case Req.head(url) do
      {:ok, response} ->
        case Req.Response.get_header(response, "content-length") do
          [value | _] ->
            case Integer.parse(value) do
              {size, _} -> size
              :error -> nil
            end

          _ ->
            nil
        end

      {:error, _error} ->
        nil
    end
  end

  defp cleanup_download_cache(cache_pid, current_uuid) when is_binary(current_uuid) do
    downloads_rel = DownloadCache.cache_path()
    downloads_abs = Cache.abs_path(cache_pid, downloads_rel)

    Logger.info(
      "[Distributions] Cache cleanup: inspecting '#{downloads_abs}', keeping current UUID #{current_uuid}"
    )

    case Cache.ls(cache_pid, downloads_rel) do
      {:ok, entries} ->
        others = Enum.filter(entries, fn entry -> entry != current_uuid end)

        if others == [] do
          Logger.info("[Distributions] Cache cleanup: no other entries to delete")
          :ok
        else
          Logger.info(
            "[Distributions] Cache cleanup: found #{length(others)} old entr" <>
              if(length(others) == 1, do: "y", else: "ies") <>
              ": #{Enum.join(others, ", ")}"
          )

          Enum.each(others, fn entry ->
            target_rel = Path.join(downloads_rel, entry)
            target_abs = Cache.abs_path(cache_pid, target_rel)
            Logger.info("[Distributions] Cache cleanup: deleting '#{target_abs}'")

            case Cache.rm_rf(cache_pid, target_rel) do
              {:ok, _removed} ->
                Logger.info("[Distributions] Cache cleanup: deleted '#{target_abs}'")

              {:error, failed, _acc} ->
                Logger.warning(
                  "[Distributions] Cache cleanup: failed deleting '#{target_abs}': #{inspect(failed)}"
                )

              other ->
                Logger.warning(
                  "[Distributions] Cache cleanup: unexpected response deleting '#{target_abs}': #{inspect(other)}"
                )
            end
          end)

          :ok
        end

      {:error, :enoent} ->
        Logger.info(
          "[Distributions] Cache cleanup: downloads directory does not exist at '#{downloads_abs}'"
        )

        :ok

      {:error, reason} ->
        Logger.warning(
          "[Distributions] Cache cleanup: unable to list '#{downloads_abs}': #{inspect(reason)}"
        )

        :ok
    end
  end

  defp try_send(nil, _msg), do: :ok

  defp try_send(pid, msg) do
    if Process.alive?(pid) do
      send(pid, msg)
    end
  end

  defp handle_cached_download_complete(%State{} = state) do
    firmware_uuid = state.distribution && state.distribution.firmware_meta.uuid

    # For parallel downloads, we don't rename files since we're streaming chunks directly
    final_state =
      if state.next_chunk_to_stream != nil do
        # This was a parallel download - log completion but don't try to process a final file
        Logger.info(
          "[Distributions] Parallel download complete - all chunks have been downloaded and are being streamed to FWUP"
        )

        state
      else
        # This was a regular download - handle normally
        final_rel_path =
          if state.download_file_path do
            rename_completed_download(state, firmware_uuid)
          else
            state.download_file_path
          end

        if final_rel_path do
          final_abs_path = Cache.abs_path(state.config.cache_pid, final_rel_path)
          %{size: file_size, hash: file_hash} = get_file_info(final_abs_path)

          Logger.info(
            "[Distributions] Firmware cached complete path=#{final_abs_path} size=#{file_size} sha256=#{file_hash}"
          )

          %State{state | download_file_path: final_rel_path}
        else
          state
        end
      end

    {:noreply, %State{final_state | download: nil}}
  end

  defp handle_streamed_download_complete(%State{} = state) do
    Logger.info("[Distributions] Firmware download complete (streamed to fwup)")
    {:noreply, %State{state | download: nil, download_file_path: state.download_file_path}}
  end

  defp pre_stream_existing_if_needed(plan, %State{} = state) do
    case plan do
      {:non_parallel_resume, _existing_size} ->
        # Stream existing .part file to FWUP before resuming network
        rel = state.download_file_path

        if is_binary(rel) do
          abs = Cache.abs_path(state.config.cache_pid, rel)
          Logger.info("[Distributions] Pre-streaming existing cached bytes to FWUP from #{abs}")
          # Use async streaming for pre-streaming too, to prevent blocking
          initiate_async_chunk_stream(abs, state)
        else
          state
        end

      {:parallel, total_size, _final_rel_path} ->
        # Initialize ordering state; existing completed chunks will be notified by downloader init
        num_chunks =
          div(total_size, state.config.distributions_download_parallel_chunk_bytes) +
            if(rem(total_size, state.config.distributions_download_parallel_chunk_bytes) > 0,
              do: 1,
              else: 0
            )

        %State{state | next_chunk_to_stream: 0, total_chunks: num_chunks, ready_chunk_files: %{}}

      _ ->
        state
    end
  end

  defp stream_ready_chunks_in_order(%State{next_chunk_to_stream: nil} = state), do: state

  defp stream_ready_chunks_in_order(%State{async_streaming: %{}} = state) do
    # Already streaming a chunk, wait for it to complete
    state
  end

  defp stream_ready_chunks_in_order(%State{} = state) do
    next = state.next_chunk_to_stream

    case Map.get(state.ready_chunk_files, next) do
      nil ->
        # Next chunk in sequence is not ready yet
        state

      rel_path ->
        # Next chunk is ready, stream it
        abs = Cache.abs_path(state.config.cache_pid, rel_path)

        Logger.info("[Distributions] Streaming completed chunk ##{next + 1} -> FWUP from #{abs}")

        # Remove this chunk from ready list and increment counter
        updated_ready = Map.delete(state.ready_chunk_files, next)

        state_with_updated_ready = %State{
          state
          | ready_chunk_files: updated_ready,
            next_chunk_to_stream: next + 1
        }

        # Use async streaming for chunks to prevent blocking
        initiate_async_chunk_stream(abs, state_with_updated_ready)
    end
  end

  defp initiate_async_chunk_stream(abs_path, %State{} = state) do
    # Check file size and decide streaming strategy
    case File.stat(abs_path) do
      {:ok, %File.Stat{size: file_size}} ->
        chunk_size = state.config.fwup_stream_chunk_bytes

        Logger.debug(
          "[Distributions] Processing chunk file: #{Path.basename(abs_path)}, file size: #{file_size} bytes, FWUP stream chunk size: #{chunk_size} bytes"
        )

        if file_size <= chunk_size do
          # Small file - read and stream entire file at once (non-blocking)
          Logger.debug(
            "[Distributions] Small chunk file (#{file_size} bytes ≤ #{chunk_size} bytes) - streaming entire file"
          )

          send(self(), {:async_stream_small_chunk_file, abs_path})
          state
        else
          # Large file - use incremental streaming to prevent blocking
          Logger.info(
            "[Distributions] Large chunk file (#{file_size} bytes > #{chunk_size} bytes) - using incremental streaming"
          )

          # Only start incremental streaming if not already streaming something else
          case state.async_streaming do
            nil ->
              async_streaming = %{
                file_path: abs_path,
                offset: 0,
                file_size: file_size
              }

              send(self(), {:async_stream_file, abs_path, 0})
              %{state | async_streaming: async_streaming}

            _ ->
              # This should not happen with proper sequential ordering
              Logger.error(
                "[Distributions] CRITICAL: Attempted to stream chunk while another stream is active"
              )

              %{
                state
                | status:
                    {:fwup_error,
                     "Concurrent streaming attempted - this indicates a bug in sequential ordering"}
              }
          end
        end

      {:error, reason} ->
        Logger.error("[Distributions] Cannot stat chunk file: #{inspect(reason)}")
        %{state | status: {:fwup_error, "Chunk file stat failed: #{inspect(reason)}"}}
    end
  end

  # Helper function for incremental streaming of large files
  defp handle_async_stream_chunk(file_path, offset, %State{} = state) do
    try do
      case File.open(file_path, [:read, :binary]) do
        {:ok, file} ->
          :file.position(file, offset)

          case IO.binread(file, state.config.fwup_stream_chunk_bytes) do
            data when is_binary(data) ->
              File.close(file)
              Logger.info("[Distributions] Sending chunk to FWUP: #{byte_size(data)} bytes")

              # Send chunk to FWUP
              if state.fwup do
                try do
                  :ok = Fwup.Stream.send_chunk(state.fwup, data)

                  # Schedule next chunk
                  next_offset = offset + byte_size(data)
                  send(self(), {:async_stream_file, file_path, next_offset})

                  {:noreply, state}
                rescue
                  e ->
                    Logger.error("[Distributions] Failed to send chunk to FWUP: #{inspect(e)}")

                    state = %{
                      state
                      | async_streaming: nil,
                        status: {:fwup_error, "Streaming failed: #{inspect(e)}"}
                    }

                    {:noreply, state}
                end
              else
                Logger.error("[Distributions] FWUP process not available during async streaming")

                state = %{
                  state
                  | async_streaming: nil,
                    status: {:fwup_error, "FWUP process not available"}
                }

                {:noreply, state}
              end

            :eof ->
              File.close(file)
              Logger.info("[Distributions] Reached EOF during async streaming")
              send(self(), {:async_stream_file, file_path, state.async_streaming.file_size})
              {:noreply, state}

            {:error, reason} ->
              File.close(file)

              Logger.error(
                "[Distributions] Failed to read chunk during async streaming: #{inspect(reason)}"
              )

              state = %{
                state
                | async_streaming: nil,
                  status: {:fwup_error, "Read failed: #{inspect(reason)}"}
              }

              {:noreply, state}
          end

        {:error, reason} ->
          Logger.error(
            "[Distributions] Failed to open file for async streaming: #{inspect(reason)}"
          )

          state = %{
            state
            | async_streaming: nil,
              status: {:fwup_error, "File open failed: #{inspect(reason)}"}
          }

          {:noreply, state}
      end
    rescue
      e ->
        Logger.error("[Distributions] Exception during async streaming: #{inspect(e)}")

        state = %{
          state
          | async_streaming: nil,
            status: {:fwup_error, "Streaming exception: #{inspect(e)}"}
        }

        {:noreply, state}
    end
  end
end

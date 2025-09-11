defmodule Peridiod.Binary.ParallelDownloader do
  @moduledoc """
  Coordinates parallel chunk downloads for a single file.

  This GenServer manages multiple ChunkDownloader processes to download
  different parts of a file simultaneously, then reassembles them into
  the final file when all chunks are complete.
  """

  use GenServer

  alias Peridiod.Binary.{
    ParallelDownloader,
    ChunkDownloader,
    Downloader.RetryConfig
  }

  require Logger
  alias Peridiod.Cache

  defstruct id: nil,
            uri: nil,
            total_size: 0,
            chunk_size: 0,
            parallel_count: 1,
            chunks: %{},
            active_downloads: %{},
            completed_chunks: MapSet.new(),
            failed_chunks: MapSet.new(),
            handler_fun: nil,
            retry_args: nil,
            final_rel_path: nil,
            cache_pid: nil,
            max_timeout: nil

  @type chunk_info :: %{
          number: non_neg_integer(),
          start_byte: non_neg_integer(),
          end_byte: non_neg_integer(),
          file_path: String.t(),
          size: non_neg_integer(),
          downloaded: non_neg_integer(),
          complete?: boolean()
        }

  @type handler_event :: {:progress, map()} | {:error, any()} | :complete
  @type event_handler_fun :: (handler_event -> any())
  @type retry_args :: RetryConfig.t()

  @type t :: %ParallelDownloader{
          id: nil | String.t(),
          uri: nil | URI.t(),
          total_size: non_neg_integer(),
          chunk_size: pos_integer(),
          parallel_count: pos_integer(),
          chunks: %{non_neg_integer() => chunk_info()},
          active_downloads: %{non_neg_integer() => pid()},
          completed_chunks: MapSet.t(),
          failed_chunks: MapSet.t(),
          handler_fun: event_handler_fun(),
          retry_args: retry_args(),
          final_rel_path: String.t(),
          cache_pid: pid() | atom(),
          max_timeout: reference()
        }

  def child_spec(
        id,
        uri,
        total_size,
        chunk_size,
        parallel_count,
        final_rel_path,
        cache_pid,
        fun,
        %RetryConfig{} = retry_args
      ) do
    %{
      id: Module.concat(__MODULE__, id),
      start:
        {__MODULE__, :start_link,
         [
           id,
           uri,
           total_size,
           chunk_size,
           parallel_count,
           final_rel_path,
           cache_pid,
           fun,
           retry_args
         ]},
      shutdown: 10000,
      type: :worker,
      restart: :transient
    }
  end

  @spec start_link(
          String.t(),
          String.t() | URI.t(),
          non_neg_integer(),
          pos_integer(),
          pos_integer(),
          String.t(),
          pid() | atom(),
          event_handler_fun(),
          RetryConfig.t()
        ) :: GenServer.on_start()
  def start_link(
        id,
        uri,
        total_size,
        chunk_size,
        parallel_count,
        final_rel_path,
        cache_pid,
        fun,
        %RetryConfig{} = retry_args
      )
      when is_function(fun, 1) do
    GenServer.start_link(__MODULE__, [
      id,
      uri,
      total_size,
      chunk_size,
      parallel_count,
      final_rel_path,
      cache_pid,
      fun,
      retry_args
    ])
  end

  def stop(pid) do
    GenServer.stop(pid)
  end

  @impl GenServer
  def init([
        id,
        uri,
        total_size,
        chunk_size,
        parallel_count,
        final_rel_path,
        cache_pid,
        fun,
        %RetryConfig{} = retry_args
      ]) do
    timer = Process.send_after(self(), :max_timeout, retry_args.max_timeout)

    Logger.info(
      "[Parallel Downloader #{id}] Starting parallel download: #{total_size} bytes in #{chunk_size} byte chunks with up to #{parallel_count} parallel downloads"
    )

    uri_parsed = if is_binary(uri), do: URI.parse(uri), else: uri

    # Calculate chunks and check for existing partial files using relative cache paths
    chunks = calculate_chunks(total_size, chunk_size, final_rel_path)
    Logger.info("[Parallel Downloader #{id}] Calculated #{map_size(chunks)} chunks")

    # Check for existing chunk files and update chunk info
    chunks = check_existing_chunks(chunks, cache_pid)

    completed_chunks =
      chunks
      |> Enum.filter(fn {_num, chunk} -> chunk.complete? end)
      |> Enum.map(fn {num, _chunk} -> num end)
      |> MapSet.new()

    state = %ParallelDownloader{
      id: id,
      uri: uri_parsed,
      total_size: total_size,
      chunk_size: chunk_size,
      parallel_count: parallel_count,
      chunks: chunks,
      active_downloads: %{},
      completed_chunks: completed_chunks,
      failed_chunks: MapSet.new(),
      handler_fun: fun,
      retry_args: retry_args,
      final_rel_path: final_rel_path,
      cache_pid: cache_pid,
      max_timeout: timer
    }

    # Start downloading chunks
    send(self(), :start_downloads)
    # Emit completion events for any already-completed chunks so upstream can stream in-order
    send(self(), :emit_existing_completed)

    {:ok, state}
  end

  @impl GenServer
  def handle_info(:max_timeout, %ParallelDownloader{} = state) do
    Logger.error("[Parallel Downloader #{state.id}] Max timeout reached, stopping all downloads")
    stop_all_active_downloads(state)
    {:stop, :max_timeout_reached, state}
  end

  def handle_info(:start_downloads, %ParallelDownloader{} = state) do
    state = start_next_downloads(state)
    {:noreply, state}
  end

  # Inform handler about chunks that were already complete on startup (in order)
  def handle_info(:emit_existing_completed, %ParallelDownloader{} = state) do
    0..(map_size(state.chunks) - 1)
    |> Enum.each(fn chunk_number ->
      case Map.get(state.chunks, chunk_number) do
        %{complete?: true, file_path: rel_path} ->
          _ = state.handler_fun.({:chunk_complete, chunk_number, rel_path})

        _ ->
          :ok
      end
    end)

    {:noreply, state}
  end

  # Handle chunk download completion
  def handle_info({:chunk_complete, chunk_number}, %ParallelDownloader{} = state) do
    chunk = Map.get(state.chunks, chunk_number)

    Logger.info(
      "[Parallel Downloader #{state.id}] Download chunk completed: #{Path.basename(chunk.file_path)} (#{chunk.size} bytes, range #{chunk.start_byte}-#{chunk.end_byte})"
    )

    state = %{
      state
      | completed_chunks: MapSet.put(state.completed_chunks, chunk_number),
        active_downloads: Map.delete(state.active_downloads, chunk_number)
    }

    # Update chunk info
    chunks =
      Map.update!(state.chunks, chunk_number, fn chunk ->
        %{chunk | complete?: true, downloaded: chunk.size}
      end)

    state = %{state | chunks: chunks}

    # Notify handler that this chunk completed so upstream can stream it
    _ = state.handler_fun.({:chunk_complete, chunk_number, chunk.file_path})

    # Send progress update
    send_progress_update(state)

    # Check if all chunks are complete
    if MapSet.size(state.completed_chunks) == map_size(state.chunks) do
      Logger.info("[Parallel Downloader #{state.id}] All chunks completed, assembling final file")

      case assemble_final_file(state) do
        :ok ->
          _ = state.handler_fun.(:complete)
          {:stop, :normal, state}

        {:error, reason} ->
          Logger.error(
            "[Parallel Downloader #{state.id}] Failed to assemble final file: #{inspect(reason)}"
          )

          _ = state.handler_fun.({:error, {:assembly_failed, reason}})
          {:stop, {:assembly_failed, reason}, state}
      end
    else
      # Start next downloads
      state = start_next_downloads(state)
      {:noreply, state}
    end
  end

  # Handle chunk download error
  def handle_info({:chunk_error, chunk_number, reason}, %ParallelDownloader{} = state) do
    chunk = Map.get(state.chunks, chunk_number)

    Logger.warning(
      "[Parallel Downloader #{state.id}] Download chunk errored: #{Path.basename(chunk.file_path)} (#{chunk.downloaded}/#{chunk.size} bytes, range #{chunk.start_byte}-#{chunk.end_byte}) - #{inspect(reason)} - will retry"
    )

    state = %{
      state
      | failed_chunks: MapSet.put(state.failed_chunks, chunk_number),
        active_downloads: Map.delete(state.active_downloads, chunk_number)
    }

    # For now, we'll retry failed chunks by starting them again
    # In a more sophisticated implementation, we might have retry limits per chunk
    state = start_next_downloads(state)
    {:noreply, state}
  end

  # Handle chunk download progress
  def handle_info(
        {:chunk_progress, chunk_number, downloaded_bytes},
        %ParallelDownloader{} = state
      ) do
    # Update chunk progress
    chunks =
      Map.update!(state.chunks, chunk_number, fn chunk ->
        %{chunk | downloaded: downloaded_bytes}
      end)

    state = %{state | chunks: chunks}

    # Send progress update (throttled)
    send_progress_update(state)

    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, %ParallelDownloader{} = state) do
    # Find which chunk this PID was handling
    case Enum.find(state.active_downloads, fn {_chunk, chunk_pid} -> chunk_pid == pid end) do
      {chunk_number, ^pid} ->
        Logger.warning(
          "[Parallel Downloader #{state.id}] Chunk #{chunk_number} process died: #{inspect(reason)} - will retry"
        )

        send(self(), {:chunk_error, chunk_number, reason})
        {:noreply, state}

      nil ->
        # Unknown process died, ignore
        {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # Private functions

  @spec calculate_chunks(non_neg_integer(), pos_integer(), String.t()) :: %{
          non_neg_integer() => chunk_info()
        }
  defp calculate_chunks(total_size, chunk_size, final_rel_path) do
    num_chunks = div(total_size, chunk_size) + if rem(total_size, chunk_size) > 0, do: 1, else: 0

    0..(num_chunks - 1)
    |> Enum.map(fn chunk_number ->
      start_byte = chunk_number * chunk_size
      end_byte = min(start_byte + chunk_size - 1, total_size - 1)
      actual_size = end_byte - start_byte + 1
      chunk_file_path = get_chunk_file_path(final_rel_path, chunk_number)

      chunk_info = %{
        number: chunk_number,
        start_byte: start_byte,
        end_byte: end_byte,
        file_path: chunk_file_path,
        size: actual_size,
        downloaded: 0,
        complete?: false
      }

      {chunk_number, chunk_info}
    end)
    |> Map.new()
  end

  @spec check_existing_chunks(%{non_neg_integer() => chunk_info()}, pid() | atom()) :: %{
          non_neg_integer() => chunk_info()
        }
  defp check_existing_chunks(chunks, cache_pid) do
    # First, log all existing files for debugging
    Logger.info("[Parallel Downloader] Checking existing chunk files:")

    chunk_files_info =
      chunks
      |> Enum.map(fn {_chunk_number, chunk} ->
        abs = Cache.abs_path(cache_pid, chunk.file_path)

        case File.stat(abs) do
          {:ok, %File.Stat{size: size}} ->
            "#{Path.basename(chunk.file_path)}:#{size}bytes"

          _ ->
            "#{Path.basename(chunk.file_path)}:missing"
        end
      end)
      |> Enum.join(", ")

    Logger.info("[Parallel Downloader] Existing files: [#{chunk_files_info}]")

    # Now process each chunk
    Enum.map(chunks, fn {chunk_number, chunk} ->
      # The chunk.size field already contains the correct expected size for this specific chunk
      # (including smaller size for the last chunk)
      expected_chunk_size = chunk.size

      abs = Cache.abs_path(cache_pid, chunk.file_path)

      case File.stat(abs) do
        {:ok, %File.Stat{size: size}} when size == expected_chunk_size ->
          # Chunk is complete - file size matches the expected size for this chunk
          Logger.info(
            "[Parallel Downloader] Found complete chunk: #{Path.basename(chunk.file_path)} (#{size}/#{expected_chunk_size} bytes)"
          )

          {chunk_number, %{chunk | downloaded: size, complete?: true}}

        {:ok, %File.Stat{size: size}} when size > 0 and size < expected_chunk_size ->
          # Partial chunk exists - preserve this data and resume from where it left off
          Logger.info(
            "[Parallel Downloader] Found partial chunk: #{Path.basename(chunk.file_path)} (#{size}/#{expected_chunk_size} bytes) - will resume"
          )

          {chunk_number, %{chunk | downloaded: size, complete?: false}}

        {:ok, %File.Stat{size: size}} when size > expected_chunk_size ->
          # File is larger than expected - something went wrong, start over with this chunk
          Logger.warning(
            "[Parallel Downloader] Found oversized chunk: #{Path.basename(chunk.file_path)} (#{size}/#{expected_chunk_size} bytes) - will restart from beginning"
          )

          {chunk_number, %{chunk | downloaded: 0, complete?: false}}

        _ ->
          # No chunk file or invalid size - start from scratch
          {chunk_number, chunk}
      end
    end)
    |> Map.new()
  end

  @spec start_next_downloads(t()) :: t()
  defp start_next_downloads(%ParallelDownloader{} = state) do
    # Find chunks that need downloading (not complete, not currently downloading, not failed recently)
    available_slots = state.parallel_count - map_size(state.active_downloads)

    if available_slots > 0 do
      chunks_to_download =
        state.chunks
        |> Enum.filter(fn {chunk_number, chunk} ->
          not chunk.complete? and
            not Map.has_key?(state.active_downloads, chunk_number) and
            not MapSet.member?(state.failed_chunks, chunk_number)
        end)
        |> Enum.take(available_slots)

      Enum.reduce(chunks_to_download, state, fn {chunk_number, chunk}, acc_state ->
        start_chunk_download(acc_state, chunk_number, chunk)
      end)
    else
      state
    end
  end

  @spec start_chunk_download(t(), non_neg_integer(), chunk_info()) :: t()
  defp start_chunk_download(%ParallelDownloader{} = state, chunk_number, chunk) do
    # Create handler function for this chunk
    parent_pid = self()

    handler_fun = fn
      {:stream, data} ->
        # Write data to chunk file via Cache
        case Cache.write_stream_update(state.cache_pid, chunk.file_path, data) do
          :ok ->
            # Update progress
            send(parent_pid, {:chunk_progress, chunk_number, chunk.downloaded + byte_size(data)})

          {:error, reason} ->
            Logger.error(
              "[Parallel Downloader #{state.id}] Failed to write chunk #{chunk_number}: #{inspect(reason)}"
            )

            send(parent_pid, {:chunk_error, chunk_number, {:file_write_error, reason}})
        end

      {:error, reason} ->
        send(parent_pid, {:chunk_error, chunk_number, reason})

      :complete ->
        send(parent_pid, {:chunk_complete, chunk_number})
    end

    # Ensure chunk directory exists in cache dir
    chunk_abs = Cache.abs_path(state.cache_pid, chunk.file_path)

    chunk_abs
    |> Path.dirname()
    |> File.mkdir_p()

    # Start chunk downloader
    case start_chunk_downloader(state, chunk_number, chunk, handler_fun) do
      {:ok, pid} ->
        # Monitor the process
        Process.monitor(pid)

        if chunk.downloaded > 0 do
          Logger.warning(
            "[Parallel Downloader #{state.id}] Resuming partially downloaded chunk: #{Path.basename(chunk.file_path)} (#{chunk.downloaded}/#{chunk.size} bytes, range #{chunk.start_byte}-#{chunk.end_byte})"
          )
        end

        # Log chunk start
        resume_info =
          if chunk.downloaded > 0, do: " (resuming from #{chunk.downloaded} bytes)", else: ""

        Logger.info(
          "[Parallel Downloader #{state.id}] Starting download chunk: #{Path.basename(chunk.file_path)} (range #{chunk.start_byte}-#{chunk.end_byte})#{resume_info}"
        )

        %{
          state
          | active_downloads: Map.put(state.active_downloads, chunk_number, pid),
            failed_chunks: MapSet.delete(state.failed_chunks, chunk_number)
        }

      {:error, :chunk_already_complete} ->
        # Chunk is already complete, mark it as such and continue
        %{
          state
          | completed_chunks: MapSet.put(state.completed_chunks, chunk_number),
            failed_chunks: MapSet.delete(state.failed_chunks, chunk_number)
        }

      {:error, reason} ->
        Logger.error(
          "[Parallel Downloader #{state.id}] Failed to start chunk #{chunk_number}: #{inspect(reason)}"
        )

        %{state | failed_chunks: MapSet.put(state.failed_chunks, chunk_number)}
    end
  end

  @spec start_chunk_downloader(t(), non_neg_integer(), chunk_info(), function()) ::
          {:ok, pid()} | {:error, any()}
  defp start_chunk_downloader(%ParallelDownloader{} = state, chunk_number, chunk, handler_fun) do
    # Don't start downloader for chunks that are already complete
    if chunk.complete? do
      Logger.warning(
        "[Parallel Downloader #{state.id}] Attempted to start downloader for complete chunk #{chunk_number}"
      )

      {:error, :chunk_already_complete}
    else
      if chunk.downloaded > 0 do
        # Resume existing chunk
        ChunkDownloader.start_link_with_resume(
          state.id,
          state.uri,
          chunk_number,
          chunk.start_byte,
          chunk.end_byte,
          chunk.file_path,
          handler_fun,
          state.retry_args,
          chunk.downloaded
        )
      else
        # Start new chunk
        ChunkDownloader.start_link(
          state.id,
          state.uri,
          chunk_number,
          chunk.start_byte,
          chunk.end_byte,
          chunk.file_path,
          handler_fun,
          state.retry_args
        )
      end
    end
  end

  @spec stop_all_active_downloads(t()) :: :ok
  defp stop_all_active_downloads(%ParallelDownloader{} = state) do
    Enum.each(state.active_downloads, fn {_chunk_number, pid} ->
      if Process.alive?(pid) do
        ChunkDownloader.stop(pid)
      end
    end)
  end

  @spec send_progress_update(t()) :: :ok
  defp send_progress_update(%ParallelDownloader{} = state) do
    total_downloaded =
      state.chunks
      |> Enum.map(fn {_num, chunk} -> chunk.downloaded end)
      |> Enum.sum()

    progress = %{
      total_size: state.total_size,
      downloaded: total_downloaded,
      percentage:
        if(state.total_size > 0, do: total_downloaded / state.total_size * 100, else: 0),
      completed_chunks: MapSet.size(state.completed_chunks),
      total_chunks: map_size(state.chunks),
      active_downloads: map_size(state.active_downloads)
    }

    # Send progress without logging (to avoid noise)
    _ = state.handler_fun.({:progress, progress})
    :ok
  end

  @spec assemble_final_file(t()) :: :ok | {:error, any()}
  defp assemble_final_file(%ParallelDownloader{} = state) do
    # Log all parts being combined with their sizes
    chunk_info =
      0..(map_size(state.chunks) - 1)
      |> Enum.map(fn chunk_number ->
        chunk = Map.get(state.chunks, chunk_number)
        "#{Path.basename(chunk.file_path)}:#{chunk.size}bytes"
      end)
      |> Enum.join(", ")

    Logger.info(
      "[Parallel Downloader #{state.id}] All parts completed, combining chunks: [#{chunk_info}] -> #{Cache.abs_path(state.cache_pid, state.final_rel_path)} (expected #{state.total_size} bytes)"
    )

    # Ensure final file directory exists
    Cache.abs_path(state.cache_pid, state.final_rel_path)
    |> Path.dirname()
    |> File.mkdir_p()

    # Open final file for writing
    case File.open(Cache.abs_path(state.cache_pid, state.final_rel_path), [:write, :binary]) do
      {:ok, final_file} ->
        result =
          try do
            # Write chunks in order
            0..(map_size(state.chunks) - 1)
            |> Enum.reduce_while(:ok, fn chunk_number, :ok ->
              chunk = Map.get(state.chunks, chunk_number)

              case File.read(Cache.abs_path(state.cache_pid, chunk.file_path)) do
                {:ok, data} ->
                  case IO.binwrite(final_file, data) do
                    :ok ->
                      {:cont, :ok}

                    error ->
                      Logger.error(
                        "[Parallel Downloader #{state.id}] Failed to write chunk #{chunk_number} to final file: #{inspect(error)}"
                      )

                      {:halt, {:error, {:write_error, error}}}
                  end

                {:error, reason} ->
                  Logger.error(
                    "[Parallel Downloader #{state.id}] Failed to read chunk #{chunk_number} (#{Path.basename(chunk.file_path)}): #{inspect(reason)}"
                  )

                  {:halt, {:error, {:read_error, chunk_number, reason}}}
              end
            end)
          after
            File.close(final_file)
          end

        case result do
          :ok ->
            # Verify final file size
            case File.stat(Cache.abs_path(state.cache_pid, state.final_rel_path)) do
              {:ok, %File.Stat{size: actual_size}} when actual_size == state.total_size ->
                Logger.info(
                  "[Parallel Downloader #{state.id}] Successfully assembled final file: #{Cache.abs_path(state.cache_pid, state.final_rel_path)} (#{actual_size} bytes from #{map_size(state.chunks)} chunks)"
                )

                cleanup_chunk_files(state)
                log_final_file_info(state)
                :ok

              {:ok, %File.Stat{size: actual_size}} ->
                Logger.error(
                  "[Parallel Downloader #{state.id}] Final file size mismatch: expected #{state.total_size}, got #{actual_size}"
                )

                {:error, {:size_mismatch, state.total_size, actual_size}}

              {:error, reason} ->
                {:error, {:stat_error, reason}}
            end

          error ->
            error
        end

      {:error, reason} ->
        {:error, {:open_error, reason}}
    end
  end

  @spec cleanup_chunk_files(t()) :: :ok
  defp cleanup_chunk_files(%ParallelDownloader{} = state) do
    Logger.info(
      "[Parallel Downloader #{state.id}] Cleaning up #{map_size(state.chunks)} chunk files"
    )

    Enum.each(state.chunks, fn {_chunk_number, chunk} ->
      case File.rm(Cache.abs_path(state.cache_pid, chunk.file_path)) do
        :ok ->
          :ok

        # File already doesn't exist
        {:error, :enoent} ->
          :ok

        {:error, reason} ->
          Logger.warning(
            "[Parallel Downloader #{state.id}] Failed to cleanup chunk file #{chunk.file_path}: #{inspect(reason)}"
          )
      end
    end)
  end

  @spec log_final_file_info(t()) :: :ok
  defp log_final_file_info(%ParallelDownloader{} = state) do
    case File.stat(Cache.abs_path(state.cache_pid, state.final_rel_path)) do
      {:ok, %File.Stat{size: size}} ->
        # Calculate SHA256 hash
        case File.read(Cache.abs_path(state.cache_pid, state.final_rel_path)) do
          {:ok, data} ->
            hash = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
            Logger.info("[Parallel Downloader #{state.id}] FINAL FILE INFO:")
            Logger.info("  - Path: #{Cache.abs_path(state.cache_pid, state.final_rel_path)}")
            Logger.info("  - Size: #{size} bytes")
            Logger.info("  - SHA256: #{hash}")

          {:error, reason} ->
            Logger.warning(
              "[Parallel Downloader #{state.id}] Could not read final file for hash calculation: #{inspect(reason)}"
            )
        end

      {:error, reason} ->
        Logger.warning(
          "[Parallel Downloader #{state.id}] Could not stat final file: #{inspect(reason)}"
        )
    end

    :ok
  end

  @spec get_chunk_file_path(String.t(), non_neg_integer()) :: String.t()
  defp get_chunk_file_path(final_rel_path, chunk_number) do
    # Create chunk file name with leading zeros for proper sorting
    # e.g., firmware.bin.part0000, firmware.bin.part0001, etc. (0-based)
    chunk_suffix = String.pad_leading(Integer.to_string(chunk_number), 4, "0")
    "#{final_rel_path}.part#{chunk_suffix}"
  end
end

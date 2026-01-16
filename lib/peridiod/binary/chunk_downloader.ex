defmodule Peridiod.Binary.ChunkDownloader do
  @moduledoc """
  Handles downloading a single chunk of a file with range requests.

  This is similar to the main Downloader but specialized for downloading
  specific byte ranges of a file to support parallel chunk downloads.
  """

  use GenServer

  alias Peridiod.Binary.{
    ChunkDownloader,
    Downloader.RetryConfig,
    Downloader.TimeoutCalculation
  }

  require Logger

  defstruct id: nil,
            uri: nil,
            conn: nil,
            request_ref: nil,
            status: nil,
            response_headers: [],
            chunk_number: 0,
            range_start: 0,
            range_end: 0,
            downloaded_length: 0,
            initial_downloaded_length: 0,
            retry_number: 0,
            handler_fun: nil,
            retry_args: nil,
            max_timeout: nil,
            retry_timeout: nil,
            worst_case_timeout: nil,
            worst_case_timeout_remaining_ms: nil,
            chunk_file_path: nil

  @type handler_event :: {:stream, binary()} | {:error, any()} | :complete
  @type event_handler_fun :: (handler_event -> any())
  @type retry_args :: RetryConfig.t()

  # alias for readability
  @typep timer() :: reference()

  @type t :: %ChunkDownloader{
          id: nil | String.t(),
          uri: nil | URI.t(),
          conn: nil | Mint.HTTP.t(),
          request_ref: nil | reference(),
          status: nil | Mint.Types.status(),
          response_headers: Mint.Types.headers(),
          chunk_number: non_neg_integer(),
          range_start: non_neg_integer(),
          range_end: non_neg_integer(),
          downloaded_length: non_neg_integer(),
          initial_downloaded_length: non_neg_integer(),
          retry_number: non_neg_integer(),
          handler_fun: event_handler_fun,
          retry_args: retry_args(),
          max_timeout: timer(),
          retry_timeout: nil | timer(),
          worst_case_timeout: nil | timer(),
          worst_case_timeout_remaining_ms: nil | non_neg_integer(),
          chunk_file_path: nil | String.t()
        }

  @doc """
  Start a ChunkDownloader without linking to the caller.

  This is used by ParallelDownloader to avoid crash propagation - the parent
  monitors the ChunkDownloader instead of linking to it.
  """
  @spec start(
          String.t(),
          String.t() | URI.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          event_handler_fun(),
          RetryConfig.t()
        ) ::
          GenServer.on_start()
  def start(
        id,
        uri,
        chunk_number,
        range_start,
        range_end,
        chunk_file_path,
        fun,
        %RetryConfig{} = retry_args
      )
      when is_function(fun, 1) do
    GenServer.start(__MODULE__, [
      id,
      uri,
      chunk_number,
      range_start,
      range_end,
      chunk_file_path,
      fun,
      retry_args
    ])
  end

  @spec start_with_resume(
          String.t(),
          URI.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          String.t(),
          event_handler_fun(),
          RetryConfig.t(),
          non_neg_integer()
        ) ::
          GenServer.on_start()
  def start_with_resume(
        id,
        %URI{} = uri,
        chunk_number,
        range_start,
        range_end,
        chunk_file_path,
        fun,
        %RetryConfig{} = retry_args,
        existing_size
      )
      when is_function(fun, 1) do
    GenServer.start(__MODULE__, [
      id,
      uri,
      chunk_number,
      range_start,
      range_end,
      chunk_file_path,
      fun,
      retry_args,
      existing_size
    ])
  end

  def stop(pid) do
    GenServer.stop(pid)
  end

  @impl GenServer
  def init([
        id,
        %URI{} = uri,
        chunk_number,
        range_start,
        range_end,
        chunk_file_path,
        fun,
        %RetryConfig{} = retry_args
      ]) do
    # Remove any existing file to ensure fresh start (prevents append to oversized/corrupt files)
    case File.exists?(chunk_file_path) do
      true ->
        Logger.info(
          "[Chunk Downloader #{id}_#{chunk_number}] Removing existing file for fresh start"
        )

        File.rm(chunk_file_path)

      false ->
        :ok
    end
    |> case do
      :ok ->
        timer = Process.send_after(self(), :max_timeout, retry_args.max_timeout)

        Logger.info(
          "[Chunk Downloader #{id}_#{chunk_number}] Started for range #{range_start}-#{range_end}"
        )

        state =
          reset(%ChunkDownloader{
            id: id,
            handler_fun: fun,
            retry_args: retry_args,
            max_timeout: timer,
            uri: uri,
            chunk_number: chunk_number,
            range_start: range_start,
            range_end: range_end,
            chunk_file_path: chunk_file_path
          })

        send(self(), :resume)
        {:ok, state}

      {:error, reason} ->
        Logger.error(
          "[Chunk Downloader #{id}_#{chunk_number}] Failed to remove existing file: #{inspect(reason)} - cannot proceed"
        )

        {:stop, {:file_cleanup_failed, reason}}
    end
  end

  def init([
        id,
        %URI{} = uri,
        chunk_number,
        range_start,
        range_end,
        chunk_file_path,
        fun,
        %RetryConfig{} = retry_args,
        existing_size
      ]) do
    timer = Process.send_after(self(), :max_timeout, retry_args.max_timeout)

    # If existing_size is 0, it means we're starting over (oversized file was detected)
    # In this case, we should remove the old file and start fresh
    final_validated_size =
      if existing_size == 0 do
        Logger.info(
          "[Chunk Downloader #{id}_#{chunk_number}] Starting fresh, removing any existing file"
        )

        File.rm(chunk_file_path)
        0
      else
        # File size is valid for resumption - use existing data
        existing_size
      end

    Logger.info(
      "[Chunk Downloader #{id}_#{chunk_number}] Started with resume from #{final_validated_size} bytes for range #{range_start}-#{range_end}"
    )

    state = %ChunkDownloader{
      id: id,
      handler_fun: fun,
      retry_args: retry_args,
      max_timeout: timer,
      uri: uri,
      chunk_number: chunk_number,
      range_start: range_start,
      range_end: range_end,
      chunk_file_path: chunk_file_path,
      downloaded_length: final_validated_size,
      initial_downloaded_length: final_validated_size,
      retry_number: 0
    }

    send(self(), :resume)
    {:ok, state}
  end

  @impl GenServer
  # this message is scheduled during init/1
  # it is a extreme condition where regardless of download attempts,
  # idle timeouts etc, this entire process has lived for TOO long.
  def handle_info(:max_timeout, %ChunkDownloader{} = state) do
    {:stop, :max_timeout_reached, state}
  end

  # this message is scheduled when we receive the `content_length` value
  def handle_info(:worst_case_download_speed_timeout, %ChunkDownloader{} = state) do
    {:stop, :worst_case_download_speed_reached, state}
  end

  # this message is delivered after `state.retry_args.idle_timeout`
  # milliseconds have occurred. It indicates that many milliseconds have elapsed since
  # the last "chunk" from the HTTP server
  def handle_info(:timeout, %ChunkDownloader{handler_fun: handler} = state) do
    _ = handler.({:error, :idle_timeout})
    state = reschedule_resume(state)
    {:noreply, state}
  end

  # message is scheduled when a resumable event happens.
  def handle_info(
        :resume,
        %ChunkDownloader{
          retry_number: retry_number,
          retry_args: %RetryConfig{max_disconnects: retry_number}
        } = state
      ) do
    Logger.warning("[Chunk Downloader #{state.id}_#{state.chunk_number}] Max disconnects reached")
    {:stop, :max_disconnects_reached, state}
  end

  def handle_info(:resume, %ChunkDownloader{handler_fun: handler} = state) do
    case resume_download(state.uri, state) do
      {:ok, state} ->
        {:noreply, state, state.retry_args.idle_timeout}

      error ->
        _ = handler.(error)
        state = reschedule_resume(state)
        {:noreply, state}
    end
  end

  def handle_info(message, %ChunkDownloader{handler_fun: handler} = state) do
    case Mint.HTTP.stream(state.conn, message) do
      {:ok, conn, responses} ->
        handle_responses(responses, %{state | conn: conn})

      {:error, conn, error, responses} ->
        _ = handler.({:error, error})
        handle_responses(responses, reschedule_resume(%{state | conn: conn}))

      :unknown ->
        {:stop, :unknown, state}
    end
  end

  # schedules a message to be delivered based on retry args
  @spec reschedule_resume(t()) :: t()
  defp reschedule_resume(%ChunkDownloader{retry_number: retry_number} = state) do
    # cancel the worst_case_timeout if it was running
    worst_case_timeout_remaining_ms =
      if state.worst_case_timeout do
        Process.cancel_timer(state.worst_case_timeout) || nil
      end

    timer = Process.send_after(self(), :resume, state.retry_args.time_between_retries)

    Logger.warning(
      "[Chunk Downloader #{state.id}_#{state.chunk_number}] Increment retry counter #{retry_number + 1} -> #{retry_number + 2}"
    )

    %ChunkDownloader{
      state
      | retry_timeout: timer,
        retry_number: retry_number + 1,
        worst_case_timeout_remaining_ms: worst_case_timeout_remaining_ms
    }
  end

  @spec schedule_worst_case_timer(t()) :: t()
  # only calculate worst_case_timeout_remaining_ms is not set
  defp schedule_worst_case_timer(
         %ChunkDownloader{worst_case_timeout_remaining_ms: nil} = download
       ) do
    # For chunks, calculate timeout based on expected chunk size
    expected_size = download.range_end - download.range_start + 1
    %ChunkDownloader{retry_args: retry_config} = download
    %RetryConfig{worst_case_download_speed: speed} = retry_config
    ms = TimeoutCalculation.calculate_worst_case_timeout(expected_size, speed)

    Logger.warning(
      "[Chunk Downloader #{download.id}_#{download.chunk_number}] Worst case timeout: #{ms}"
    )

    timer = Process.send_after(self(), :worst_case_download_speed_timeout, ms)
    %ChunkDownloader{download | worst_case_timeout: timer}
  end

  # worst_case_timeout_remaining_ms gets set if the timer gets canceled by reschedule_resume/1
  # this is done so that the timer doesn't keep counting while not actively downloading data
  defp schedule_worst_case_timer(%ChunkDownloader{worst_case_timeout_remaining_ms: ms} = download) do
    timer = Process.send_after(self(), :worst_case_download_speed_timeout, ms)
    %ChunkDownloader{download | worst_case_timeout: timer}
  end

  defp handle_responses([response | rest], %ChunkDownloader{} = state) do
    case handle_response(response, state) do
      # this `status != nil` thing seems really weird. Shouldn't be needed.
      %ChunkDownloader{status: status} = state when status != nil and status >= 400 ->
        # Normal exit prevents supervisor restart and link crash propagation
        {:stop, :normal, state}

      state ->
        handle_responses(rest, state)
    end
  end

  defp handle_responses(
         [],
         %ChunkDownloader{
           downloaded_length: downloaded,
           range_start: range_start,
           range_end: range_end
         } = state
       ) do
    expected_size = range_end - range_start + 1

    # Check if chunk is complete - total downloaded should match expected chunk size
    if downloaded >= expected_size do
      _ = state.handler_fun.(:complete)
      {:stop, :normal, state}
    else
      {:noreply, state, state.retry_args.idle_timeout}
    end
  end

  @doc false
  @spec handle_response(
          {:status, reference(), non_neg_integer()} | {:headers, reference(), keyword()},
          ChunkDownloader.t()
        ) ::
          ChunkDownloader.t()
  def handle_response(
        {:status, request_ref, status},
        %ChunkDownloader{request_ref: request_ref} = state
      )
      when status >= 300 and status < 400 do
    %ChunkDownloader{state | status: status}
  end

  # the handle_responses/2 function checks this value again because this function only handles state
  def handle_response(
        {:status, request_ref, status},
        %ChunkDownloader{
          request_ref: request_ref,
          uri: uri,
          chunk_number: chunk_number,
          range_start: range_start,
          range_end: range_end
        } = state
      )
      when status >= 400 do
    # Log detailed error information for this chunk
    Logger.error(
      "[Chunk Downloader #{state.id}_#{chunk_number}] Fatal HTTP error #{status} for chunk #{chunk_number} " <>
        "(range #{range_start}-#{range_end}). URL: #{URI.to_string(uri)}"
    )

    # Send fatal error with URL for logging, then mark for clean shutdown
    state.handler_fun.({:fatal_http_error, status, uri})
    %ChunkDownloader{state | status: status}
  end

  def handle_response(
        {:status, request_ref, status},
        %ChunkDownloader{request_ref: request_ref} = state
      )
      when status >= 200 and status < 300 do
    %ChunkDownloader{state | status: status}
  end

  # handles HTTP redirects.
  def handle_response(
        {:headers, request_ref, headers},
        %ChunkDownloader{request_ref: request_ref, status: status, handler_fun: handler} = state
      )
      when status >= 300 and status < 400 do
    location = fetch_location(headers)

    Logger.debug(
      "[Chunk Downloader #{state.id}_#{state.chunk_number}] Redirecting to #{location}"
    )

    state = reset(state)

    case resume_download(location, state) do
      {:ok, %ChunkDownloader{} = state} ->
        state

      error ->
        handler.(error)
        state
    end
  end

  def handle_response(
        {:headers, request_ref, headers},
        %ChunkDownloader{request_ref: request_ref} = state
      ) do
    case fetch_accept_ranges(headers) do
      accept_ranges when accept_ranges in ["none", nil] ->
        Logger.error(
          "[Chunk Downloader #{state.id}_#{state.chunk_number}] HTTP Server does not support the Range header"
        )

      _ ->
        :ok
    end

    schedule_worst_case_timer(%ChunkDownloader{
      state
      | response_headers: headers
    })
  end

  def handle_response(
        {:data, request_ref, data},
        %ChunkDownloader{
          request_ref: request_ref,
          downloaded_length: downloaded,
          range_start: range_start,
          range_end: range_end
        } = state
      ) do
    expected_size = range_end - range_start + 1
    data_size = byte_size(data)

    # Check if adding this data would exceed the chunk size
    if downloaded + data_size > expected_size do
      # Only take the bytes we need to complete the chunk
      bytes_needed = expected_size - downloaded

      if bytes_needed > 0 do
        truncated_data = binary_part(data, 0, bytes_needed)
        _ = state.handler_fun.({:stream, truncated_data})

        Logger.warning(
          "[Chunk Downloader #{state.id}_#{state.chunk_number}] Truncated incoming data to prevent oversized chunk (#{data_size} bytes -> #{bytes_needed} bytes)"
        )

        %ChunkDownloader{state | downloaded_length: expected_size}
      else
        # We already have all the data we need
        Logger.warning(
          "[Chunk Downloader #{state.id}_#{state.chunk_number}] Ignoring excess data, chunk already complete"
        )

        state
      end
    else
      # Normal case - add all the data
      _ = state.handler_fun.({:stream, data})
      %ChunkDownloader{state | downloaded_length: downloaded + data_size}
    end
  end

  def handle_response({:done, request_ref}, %ChunkDownloader{request_ref: request_ref} = state) do
    state
  end

  # ignore other messages when redirecting
  def handle_response(_, %ChunkDownloader{status: nil} = state) do
    state
  end

  defp reset(%ChunkDownloader{} = state) do
    %ChunkDownloader{
      state
      | retry_number: 0,
        downloaded_length: 0,
        initial_downloaded_length: 0
    }
  end

  @spec resume_download(URI.t(), t()) ::
          {:ok, t()}
          | {:error, Mint.Types.error()}
          | {:error, Mint.HTTP.t(), Mint.Types.error()}
  defp resume_download(
         %URI{scheme: scheme, host: host, port: port, path: path, query: query} = uri,
         %ChunkDownloader{} = state
       )
       when scheme in ["https", "http"] do
    request_headers =
      [{"content-type", "application/octet-stream"}]
      |> add_range_header(state)
      |> add_retry_number_header(state)
      |> add_user_agent_header(state)

    # mint doesn't accept the query as the http body, so it must be encoded
    # like this. There may be a better way to do this..
    path = if query, do: "#{path}?#{query}", else: path

    # Determine current position in chunk
    current_position = state.range_start + state.downloaded_length

    Logger.info(
      "[Chunk Downloader #{state.id}_#{state.chunk_number}] CHUNK download attempt #{state.retry_number + 1} #{uri} (range #{current_position}-#{state.range_end})"
    )

    with {:ok, conn} <- Mint.HTTP.connect(String.to_existing_atom(scheme), host, port),
         {:ok, conn, request_ref} <- Mint.HTTP.request(conn, "GET", path, request_headers, nil) do
      {:ok,
       %ChunkDownloader{
         state
         | uri: uri,
           conn: conn,
           request_ref: request_ref,
           status: nil,
           response_headers: []
       }}
    end
  end

  @spec fetch_location(Mint.Types.headers()) :: nil | URI.t()
  defp fetch_location(headers)
  defp fetch_location([{"location", uri} | _]), do: URI.parse(uri)
  defp fetch_location([_ | rest]), do: fetch_location(rest)
  defp fetch_location([]), do: nil

  defp fetch_accept_ranges(headers)
  defp fetch_accept_ranges([{"accept-ranges", value} | _]), do: value
  defp fetch_accept_ranges([_ | rest]), do: fetch_accept_ranges(rest)
  defp fetch_accept_ranges([]), do: nil

  @spec add_range_header(Mint.Types.headers(), t()) :: Mint.Types.headers()
  defp add_range_header(headers, %ChunkDownloader{} = state) do
    # Calculate current position within the chunk
    current_position = state.range_start + state.downloaded_length

    # Ensure we don't create invalid ranges where start > end
    if current_position > state.range_end do
      Logger.error(
        "[Chunk Downloader #{state.id}_#{state.chunk_number}] Invalid range calculation: current_position=#{current_position} > range_end=#{state.range_end} (downloaded=#{state.downloaded_length}, range_start=#{state.range_start})"
      )

      # This chunk appears to be complete, don't add range header
      headers
    else
      range_header = "bytes=#{current_position}-#{state.range_end}"

      if state.downloaded_length > 0 do
        Logger.info(
          "[Chunk Downloader #{state.id}_#{state.chunk_number}] Retry attempt: #{Path.basename(state.chunk_file_path)} (existing #{state.downloaded_length} bytes, new range #{current_position}-#{state.range_end})"
        )
      end

      [{"Range", range_header} | headers]
    end
  end

  @spec add_retry_number_header(Mint.Types.headers(), t()) :: Mint.Types.headers()
  defp add_retry_number_header(headers, %ChunkDownloader{retry_number: retry_number}),
    do: [{"X-Retry-Number", "#{retry_number}"} | headers]

  defp add_user_agent_header(headers, _),
    do: [{"User-Agent", "Peridiod/#{Application.spec(:peridiod)[:vsn]}"} | headers]
end

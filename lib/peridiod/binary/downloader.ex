defmodule Peridiod.Binary.Downloader do
  @moduledoc """
  Handles downloading files via HTTP.
  internally caches several interesting properties about
  the download such as:

    * the URI of the request
    * the total content amounts of bytes of the file being downloaded
    * the total amount of bytes downloaded at any given time

  Using this information, it can restart a download using the
  [`Range` HTTP header](https://developer.mozilla.org/en-US/docs/Web/HTTP/Headers/Range).

  This process's **only** focus is obtaining data reliably. It doesn't have any
  side effects on the system.
  """

  use GenServer

  alias Peridiod.Binary.{
    Downloader,
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
            content_length: 0,
            downloaded_length: 0,
            initial_downloaded_length: 0,
            retry_number: 0,
            handler_fun: nil,
            retry_args: nil,
            max_timeout: nil,
            retry_timeout: nil,
            worst_case_timeout: nil,
            worst_case_timeout_remaining_ms: nil

  @type handler_event :: {:stream, binary()} | {:error, any()} | :complete
  @type event_handler_fun :: (handler_event -> any())
  @type retry_args :: RetryConfig.t()

  # alias for readability
  @typep timer() :: reference()

  @type t :: %Downloader{
          id: nil | String.t(),
          uri: nil | URI.t(),
          conn: nil | Mint.HTTP.t(),
          request_ref: nil | reference(),
          status: nil | Mint.Types.status(),
          response_headers: Mint.Types.headers(),
          content_length: non_neg_integer(),
          downloaded_length: non_neg_integer(),
          initial_downloaded_length: non_neg_integer(),
          retry_number: non_neg_integer(),
          handler_fun: event_handler_fun,
          retry_args: retry_args(),
          max_timeout: timer(),
          retry_timeout: nil | timer(),
          worst_case_timeout: nil | timer(),
          worst_case_timeout_remaining_ms: nil | non_neg_integer()
        }

  @type initialized_download :: %Downloader{
          id: String.t(),
          uri: URI.t(),
          conn: Mint.HTTP.t(),
          request_ref: reference(),
          status: nil | Mint.Types.status(),
          response_headers: Mint.Types.headers(),
          content_length: non_neg_integer(),
          downloaded_length: non_neg_integer(),
          retry_number: non_neg_integer(),
          handler_fun: event_handler_fun
        }

  # todo, this should be `t`, but with retry_timeout
  @type resume_rescheduled :: t()

  @doc """
  Begins downloading a file at `url` handled by `fun`.

  # Example

        iex> pid = self()
        #PID<0.110.0>
        iex> fun = fn {:stream, data} -> File.write("index.html", data)
        ...> {:error, error} -> IO.puts("error streaming file: \#{inspect(error)}")
        ...> :complete -> send pid, :complete
        ...> end
        #Function<44.97283095/1 in :erl_eval.expr/5>
        iex> Peridiod.Downloader.start_link("https://httpbin.com/", fun, %RetryConfig{})
        {:ok, #PID<0.111.0>}
        iex> flush()
        :complete
  """

  def child_spec(id, uri, fun, %RetryConfig{} = retry_args) do
    %{
      id: Module.concat(__MODULE__, id),
      start: {__MODULE__, :start_link, [id, uri, fun, retry_args]},
      shutdown: 5000,
      type: :worker,
      restart: :transient
    }
  end

  @spec start_link(String.t(), String.t() | URI.t(), event_handler_fun(), RetryConfig.t()) ::
          GenServer.on_start()
  def start_link(id, uri, fun, %RetryConfig{} = retry_args) when is_function(fun, 1) do
    GenServer.start_link(__MODULE__, [id, uri, fun, retry_args])
  end

  @spec start_link_with_resume(
          String.t(),
          URI.t(),
          event_handler_fun(),
          RetryConfig.t(),
          non_neg_integer()
        ) ::
          GenServer.on_start()
  def start_link_with_resume(id, %URI{} = uri, fun, %RetryConfig{} = retry_args, existing_size)
      when is_function(fun, 1) do
    GenServer.start_link(__MODULE__, [id, uri, fun, retry_args, existing_size])
  end

  def stop(pid) do
    GenServer.stop(pid)
  end

  @impl GenServer
  def init([id, %URI{} = uri, fun, %RetryConfig{} = retry_args]) do
    timer = Process.send_after(self(), :max_timeout, retry_args.max_timeout)
    Logger.info("[Stream Downloader #{id}] Started")

    state =
      reset(%Downloader{
        id: id,
        handler_fun: fun,
        retry_args: retry_args,
        max_timeout: timer,
        uri: uri
      })

    send(self(), :resume)
    {:ok, state}
  end

  def init([id, %URI{} = uri, fun, %RetryConfig{} = retry_args, existing_size]) do
    timer = Process.send_after(self(), :max_timeout, retry_args.max_timeout)
    Logger.info("[Stream Downloader #{id}] Started with resume from #{existing_size} bytes")

    state = %Downloader{
      id: id,
      handler_fun: fun,
      retry_args: retry_args,
      max_timeout: timer,
      uri: uri,
      downloaded_length: existing_size,
      initial_downloaded_length: existing_size,
      retry_number: 0,
      content_length: 0
    }

    send(self(), :resume)
    {:ok, state}
  end

  @impl GenServer
  # this message is scheduled during init/1
  # it is a extreme condition where regardless of download attempts,
  # idle timeouts etc, this entire process has lived for TOO long.
  def handle_info(:max_timeout, %Downloader{} = state) do
    {:stop, :max_timeout_reached, state}
  end

  # this message is scheduled when we receive the `content_length` value
  def handle_info(:worst_case_download_speed_timeout, %Downloader{} = state) do
    {:stop, :worst_case_download_speed_reached, state}
  end

  # this message is delivered after `state.retry_args.idle_timeout`
  # milliseconds have occurred. It indicates that many milliseconds have elapsed since
  # the last "chunk" from the HTTP server
  def handle_info(:timeout, %Downloader{handler_fun: handler} = state) do
    _ = handler.({:error, :idle_timeout})
    state = reschedule_resume(state)
    {:noreply, state}
  end

  # message is scheduled when a resumable event happens.
  def handle_info(
        :resume,
        %Downloader{
          retry_number: retry_number,
          retry_args: %RetryConfig{max_disconnects: retry_number}
        } = state
      ) do
    Logger.warning("[Stream Downloader #{state.id}] Max disconnects reached")
    {:stop, :max_disconnects_reached, state}
  end

  def handle_info(:resume, %Downloader{handler_fun: handler} = state) do
    case resume_download(state.uri, state) do
      {:ok, state} ->
        {:noreply, state, state.retry_args.idle_timeout}

      error ->
        _ = handler.(error)
        state = reschedule_resume(state)
        {:noreply, state}
    end
  end

  def handle_info(message, %Downloader{handler_fun: handler} = state) do
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
  @spec reschedule_resume(t()) :: resume_rescheduled()
  defp reschedule_resume(%Downloader{retry_number: retry_number} = state) do
    # cancel the worst_case_timeout if it was running
    worst_case_timeout_remaining_ms =
      if state.worst_case_timeout do
        Process.cancel_timer(state.worst_case_timeout) || nil
      end

    timer = Process.send_after(self(), :resume, state.retry_args.time_between_retries)
    Logger.warning("[Stream Downloader #{state.id}] Increment retry counter #{retry_number + 1}")

    %Downloader{
      state
      | retry_timeout: timer,
        retry_number: retry_number + 1,
        worst_case_timeout_remaining_ms: worst_case_timeout_remaining_ms
    }
  end

  @spec schedule_worst_case_timer(t()) :: t()
  # only calculate worst_case_timeout_remaining_ms is not set
  defp schedule_worst_case_timer(%Downloader{worst_case_timeout_remaining_ms: nil} = download) do
    # decompose here because in the formatter doesn't like all this being in the head
    %Downloader{retry_args: retry_config, content_length: content_length} = download
    %RetryConfig{worst_case_download_speed: speed} = retry_config
    ms = TimeoutCalculation.calculate_worst_case_timeout(content_length, speed)
    Logger.warning("[Stream Downloader #{download.id}] Worst case timeout: #{ms}")
    timer = Process.send_after(self(), :worst_case_download_speed_timeout, ms)
    %Downloader{download | worst_case_timeout: timer}
  end

  # worst_case_timeout_remaining_ms gets set if the timer gets canceled by reschedule_resume/1
  # this is done so that the timer doesn't keep counting while not actively downloading data
  defp schedule_worst_case_timer(%Downloader{worst_case_timeout_remaining_ms: ms} = download) do
    timer = Process.send_after(self(), :worst_case_download_speed_timeout, ms)
    %Downloader{download | worst_case_timeout: timer}
  end

  defp handle_responses([response | rest], %Downloader{} = state) do
    case handle_response(response, state) do
      # this `status != nil` thing seems really weird. Shouldn't be needed.
      %Downloader{status: status} = state when status != nil and status >= 400 ->
        {:stop, {:http_error, status}, state}

      state ->
        handle_responses(rest, state)
    end
  end

  defp handle_responses(
         [],
         %Downloader{
           downloaded_length: downloaded,
           content_length: content_length,
           initial_downloaded_length: initial
         } = state
       )
       when downloaded != 0 and content_length > 0 and downloaded - initial >= content_length do
    # For range requests: downloaded_length - initial_downloaded_length should equal content_length
    # For full downloads: downloaded_length should equal content_length (initial is 0)
    _ = state.handler_fun.(:complete)
    {:stop, :normal, state}
  end

  defp handle_responses([], %Downloader{} = state) do
    {:noreply, state, state.retry_args.idle_timeout}
  end

  @doc false
  @spec handle_response(
          {:status, reference(), non_neg_integer()} | {:headers, reference(), keyword()},
          Downloader.t()
        ) ::
          Downloader.t()
  def handle_response(
        {:status, request_ref, status},
        %Downloader{request_ref: request_ref} = state
      )
      when status >= 300 and status < 400 do
    %Downloader{state | status: status}
  end

  # the handle_responses/2 function checks this value again because this function only handles state
  def handle_response(
        {:status, request_ref, status},
        %Downloader{request_ref: request_ref} = state
      )
      when status >= 400 do
    # kind of a hack to make the error type uniform
    state.handler_fun.({:error, %Mint.HTTPError{reason: {:http_error, status}}})
    %Downloader{state | status: status}
  end

  def handle_response(
        {:status, request_ref, status},
        %Downloader{request_ref: request_ref} = state
      )
      when status >= 200 and status < 300 do
    %Downloader{state | status: status}
  end

  # handles HTTP redirects.
  def handle_response(
        {:headers, request_ref, headers},
        %Downloader{request_ref: request_ref, status: status, handler_fun: handler} = state
      )
      when status >= 300 and status < 400 do
    location = fetch_location(headers)
    Logger.debug("[Stream Downloader #{state.id}] Redirecting to #{location}")

    state = reset(state)

    case resume_download(location, state) do
      {:ok, %Downloader{} = state} ->
        state

      error ->
        handler.(error)
        state
    end
  end

  # if we already have the content-length header, don't fetch it again.
  # range requests will change this value
  def handle_response(
        {:headers, request_ref, headers},
        %Downloader{request_ref: request_ref, content_length: content_length} = state
      )
      when content_length > 0 do
    schedule_worst_case_timer(%Downloader{state | response_headers: headers})
  end

  def handle_response(
        {:headers, request_ref, headers},
        %Downloader{request_ref: request_ref, content_length: 0} = state
      ) do
    case fetch_accept_ranges(headers) do
      accept_ranges when accept_ranges in ["none", nil] ->
        Logger.error(
          "[Stream Downloader #{state.id}] HTTP Server does not support the Range header"
        )

      _ ->
        :ok
    end

    content_length = fetch_content_length(headers)

    schedule_worst_case_timer(%Downloader{
      state
      | response_headers: headers,
        content_length: content_length
    })
  end

  def handle_response(
        {:data, request_ref, data},
        %Downloader{request_ref: request_ref, downloaded_length: downloaded} = state
      ) do
    _ = state.handler_fun.({:stream, data})
    %Downloader{state | downloaded_length: downloaded + byte_size(data)}
  end

  def handle_response({:done, request_ref}, %Downloader{request_ref: request_ref} = state) do
    state
  end

  # ignore other messages when redirecting
  def handle_response(_, %Downloader{status: nil} = state) do
    state
  end

  defp reset(%Downloader{} = state) do
    %Downloader{
      state
      | retry_number: 0,
        downloaded_length: 0,
        initial_downloaded_length: 0,
        content_length: 0
    }
  end

  @spec resume_download(URI.t(), t()) ::
          {:ok, initialized_download()}
          | {:error, Mint.Types.error()}
          | {:error, Mint.HTTP.t(), Mint.Types.error()}
  defp resume_download(
         %URI{scheme: scheme, host: host, port: port, path: path, query: query} = uri,
         %Downloader{} = state
       )
       when scheme in ["https", "http"] do
    request_headers =
      [{"content-type", "application/octet-stream"}]
      |> add_range_header(state)
      |> add_retry_number_header(state)
      |> add_user_agent_header(state)

    Logger.info(
      "[Stream Downloader #{state.id}] #{if(state.downloaded_length > 0, do: "RESUME", else: "INIT")} download attempt #{state.retry_number} #{uri}"
    )

    # mint doesn't accept the query as the http body, so it must be encoded
    # like this. There may be a better way to do this..
    path = if query, do: "#{path}?#{query}", else: path

    with {:ok, conn} <- Mint.HTTP.connect(String.to_existing_atom(scheme), host, port),
         {:ok, conn, request_ref} <- Mint.HTTP.request(conn, "GET", path, request_headers, nil) do
      {:ok,
       %Downloader{
         state
         | uri: uri,
           conn: conn,
           request_ref: request_ref,
           status: nil,
           response_headers: []
       }}
    end
  end

  @spec fetch_content_length(Mint.Types.headers()) :: 0 | pos_integer()
  defp fetch_content_length(headers)
  defp fetch_content_length([{"content-length", value} | _]), do: String.to_integer(value)
  defp fetch_content_length([_ | rest]), do: fetch_content_length(rest)
  defp fetch_content_length([]), do: 0

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
  defp add_range_header(headers, %Downloader{downloaded_length: dl} = _state) when dl > 0 do
    # Use optional range-end format: bytes=start- to request from start position to end of file
    [{"Range", "bytes=#{dl}-"} | headers]
  end

  defp add_range_header(headers, _state), do: headers

  @spec add_retry_number_header(Mint.Types.headers(), t()) :: Mint.Types.headers()
  defp add_retry_number_header(headers, %Downloader{retry_number: retry_number}),
    do: [{"X-Retry-Number", "#{retry_number}"} | headers]

  defp add_user_agent_header(headers, _),
    do: [{"User-Agent", "Peridiod/#{Application.spec(:peridiod)[:vsn]}"} | headers]
end

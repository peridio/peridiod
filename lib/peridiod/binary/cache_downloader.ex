defmodule Peridiod.Binary.CacheDownloader do
  use GenServer

  require Logger

  alias Peridiod.Binary.Downloader
  alias Peridiod.{Cache, Binary}

  def child_spec(%Binary{prn: binary_prn} = binary_metadata, opts) do
    opts = Map.put_new(opts, :callback, self())

    %{
      id: Module.concat(__MODULE__, binary_prn),
      start: {__MODULE__, :start_link, [binary_metadata, opts]},
      restart: :transient,
      shutdown: 5000,
      type: :worker
    }
  end

  def start_link(%Binary{} = binary_metadata, opts) do
    GenServer.start_link(__MODULE__, {binary_metadata, opts})
  end

  def init({binary_metadata, opts}) do
    Logger.debug(
      "Cache Downloader Started: #{inspect(self())}\n#{binary_metadata.prn}\nBytes: #{binary_metadata.size}"
    )

    callback = opts.callback
    cache_pid = Map.get(opts, :cache_pid, Cache)

    pid = self()
    fun = &send(pid, {:download_cache, &1})

    {:ok, downloader} =
      Downloader.Supervisor.start_child(
        binary_metadata.prn,
        binary_metadata.uri,
        fun
      )

    Process.flag(:trap_exit, true)

    {:ok,
     %{
       callback: callback,
       cache_pid: cache_pid,
       binary_metadata: binary_metadata,
       downloader: downloader,
       bytes_downloaded: 0,
       percent_downloaded: 0.0,
       hash: :crypto.hash_init(:sha256)
     }}
  end

  def handle_info({:download_cache, {:data, data}}, state) do
    hash = :crypto.hash_update(state.hash, data)
    file = Binary.cache_file(state.binary_metadata)

    Cache.write_stream_update(state.cache_pid, file, data)

    bytes_downloaded = state.bytes_downloaded + byte_size(data)
    percent_downloaded = bytes_downloaded / state.binary_metadata.size

    send(
      state.callback,
      {:download_cache, state.binary_metadata, {:progress, percent_downloaded}}
    )

    {:noreply,
     %{
       state
       | bytes_downloaded: bytes_downloaded,
         percent_downloaded: percent_downloaded,
         hash: hash
     }}
  end

  def handle_info({:download_cache, :complete}, state) do
    Logger.debug(
      "Cache Downloader finished: #{state.bytes_downloaded}/#{state.binary_metadata.size}"
    )

    hash = :crypto.hash_final(state.hash)
    file = Binary.cache_file(state.binary_metadata)
    signature = List.first(state.binary_metadata.signatures)

    with true <- state.binary_metadata.hash == hash,
         :ok <- Cache.write_stream_finish(state.cache_pid, file, signature) do
      Binary.stamp_cached(state.cache_pid, state.binary_metadata)
      send(state.callback, {:download_cache, state.binary_metadata, :complete})
    else
      error ->
        send(state.callback, {:download_cache, state.binary_metadata, {:error, error}})
    end

    {:stop, :normal, state}
  end

  def handle_info({:download_cache, {:error, error}}, state) do
    send(state.callback, {:download_cache, state.binary_metadata, {:error, error}})
    {:stop, :normal, state}
  end

  def handle_info(msg, state) do
    Logger.debug("CacheDownloader unhandled message: #{inspect(msg)}")
    {:noreply, state}
  end
end

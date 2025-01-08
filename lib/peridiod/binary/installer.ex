defmodule Peridiod.Binary.Installer do
  use GenServer

  require Logger

  alias PeridiodPersistence.KV
  alias Peridiod.{Binary, Cache}
  alias Peridiod.Binary.{Installer, CacheDownloader, StreamDownloader}

  defmodule State do
    defstruct cache_pid: Cache,
              cache_stream: nil,
              callback: nil,
              config: nil,
              binary_metadata: nil,
              hash_accumulator: nil,
              installer_mod: nil,
              installer_opts: %{},
              installer_state: nil,
              kv_pid: KV,
              status: :initializing,
              source: nil,
              bytes_streamed: 0,
              download_percent: 0.0,
              install_percent: 0.0
  end

  def child_spec(%Binary{prn: binary_prn} = binary_metadata, opts) do
    opts = Map.put(opts, :callback, self())

    %{
      id: Module.concat(__MODULE__, binary_prn),
      start: {__MODULE__, :start_link, [binary_metadata, opts]},
      restart: :transient,
      shutdown: 5000,
      type: :worker,
      modules: [__MODULE__]
    }
  end

  def start_link(%Binary{} = binary_metadata, opts) do
    GenServer.start_link(__MODULE__, {binary_metadata, opts})
  end

  def init({binary_metadata, opts}) do
    Logger.debug("Starting Installer: #{binary_metadata.prn}")
    installer_mod = installer_mod(binary_metadata)
    installer_opts = binary_metadata.custom_metadata["peridiod"]["installer_opts"]
    cache_enabled? = Map.get(installer_opts, "cache_enabled", true)
    cache_pid = Map.get(opts, :cache_pid, Cache)
    kv_pid = Map.get(opts, :kv_pid, KV)
    callback = opts.callback
    config = Map.put(opts.config, :cache_pid, cache_pid)

    {:ok,
     %State{
       callback: callback,
       cache_pid: cache_pid,
       kv_pid: kv_pid,
       config: config,
       installer_mod: installer_mod,
       installer_opts: installer_opts,
       binary_metadata: binary_metadata
     }, {:continue, cache_enabled?}}
  end

  def handle_continue(true, %{binary_metadata: %{uri: uri}} = state) when not is_nil(uri) do
    case Binary.cached?(state.cache_pid, state.binary_metadata) do
      true ->
        Logger.debug("Installer [#{state.binary_metadata.prn}]: Installing from Cache")
        do_install_from_cache(state)
        {:noreply, %{state | status: :installing, source: :cache, download_percent: 1.0}}

      false ->
        Logger.debug("Installer [#{state.binary_metadata.prn}]: Install from download")

        do_install_from_download(state)
        {:noreply, %{state | status: :installing, source: :download}}
    end
  end

  def handle_continue(false, %{binary_metadata: %{url: nil}} = state) do
    Logger.error("Installer [#{state.binary_metadata.prn}]: No Cache / URL to Install")

    try_send(
      state.callback,
      {Installer, state.binary_metadata.prn, {:error, "no url to install"}}
    )

    {:stop, :normal, state}
  end

  def handle_continue(false, state) do
    Logger.error("Installer [#{state.binary_metadata.prn}]: Installing from download stream")
    do_install_from_download(state)
    {:noreply, state}
  end

  # Streaming from Cache
  def handle_info({:cache_install, :start}, state) do
    apply(state.installer_mod, :install_init, [
      state.binary_metadata,
      state.installer_opts,
      :cache,
      state.config
    ])
    |> installer_resp(%{state | bytes_streamed: 0})
    |> installer_progress()
  end

  def handle_info({:cache_install, :update, {:stream, data}}, state) do
    bytes_streamed = state.bytes_streamed + byte_size(data)
    install_percent = bytes_streamed / state.binary_metadata.size
    state = %{state | install_percent: install_percent, bytes_streamed: bytes_streamed}

    apply(state.installer_mod, :install_update, [
      state.binary_metadata,
      data,
      state.installer_state
    ])
    |> installer_resp(state)
    |> installer_progress()
  end

  def handle_info({:cache_install, :update, {:eof, verified_status, hash}}, state) do
    state = %{state | install_percent: 1.0, bytes_streamed: 0}

    apply(state.installer_mod, :install_finish, [
      state.binary_metadata,
      verified_status,
      hash,
      state.installer_state
    ])
    |> installer_resp(state)
    |> installer_complete()
  end

  def handle_info({:download_stream, :start}, state) do
    state = %{state | hash_accumulator: :crypto.hash_init(:sha256)}

    apply(state.installer_mod, :install_init, [
      state.binary_metadata,
      state.installer_opts,
      :download,
      state.config
    ])
    |> installer_resp(state)
    |> installer_progress()
  end

  def handle_info({:download_cache, :start}, state) do
    apply(state.installer_mod, :install_init, [
      state.binary_metadata,
      state.installer_opts,
      :download,
      state.config
    ])
    |> installer_resp(state)
    |> installer_progress()
  end

  def handle_info({:download_stream, :complete}, state) do
    hash = :crypto.hash_final(state.hash_accumulator)
    state = %{state | install_percent: 1.0, hash_accumulator: hash, bytes_streamed: 0}
    [signature] = state.binary_metadata.signatures

    expected_hash = state.binary_metadata.hash
    valid_hash? = expected_hash == hash

    valid_signature? =
      Binary.valid_signature?(
        Base.encode16(hash, case: :lower),
        signature.signature,
        signature.signing_key.public_der
      )

    validity =
      case {valid_hash?, valid_signature?} do
        {true, true} -> :valid_signature
        {true, false} -> :invalid_signature
        {false, _} -> :invalid_hash
      end

    apply(state.installer_mod, :install_finish, [
      state.binary_metadata,
      validity,
      hash,
      state.installer_state
    ])
    |> installer_resp(state)
    |> installer_complete()
  end

  def handle_info({:download_cache, _binary_metadata, :complete}, state) do
    apply(state.installer_mod, :install_finish, [
      state.binary_metadata,
      :valid_signature,
      nil,
      state.installer_state
    ])
    |> installer_resp(state)
    |> installer_complete()
  end

  def handle_info({:download_stream, {:error, reason}}, state) do
    apply(state.installer_mod, :install_error, [
      state.binary_metadata,
      reason,
      state.installer_state
    ])
    |> installer_resp(state)
    |> installer_error()
  end

  def handle_info({:download_cache, _binary_metadata, {:error, reason}}, state) do
    apply(state.installer_mod, :install_error, [
      state.binary_metadata,
      reason,
      state.installer_state
    ])
    |> installer_resp(state)
    |> installer_error()
  end

  def handle_info({:download_stream, {:data, data}}, state) do
    hash = :crypto.hash_update(state.hash_accumulator, data)
    bytes_streamed = state.bytes_streamed + byte_size(data)
    install_percent = bytes_streamed / state.binary_metadata.size

    state = %{
      state
      | install_percent: install_percent,
        hash_accumulator: hash,
        bytes_streamed: bytes_streamed
    }

    apply(state.installer_mod, :install_update, [
      state.binary_metadata,
      data,
      state.installer_state
    ])
    |> installer_resp(state)
    |> installer_progress()
  end

  def handle_info({:download_cache, _binary_metadata, {:progress, percent_downloaded}}, state) do
    state = %{
      state
      | install_percent: percent_downloaded
    }

    installer_progress({:noreply, state})
  end

  def handle_info(msg, state) do
    apply(state.installer_mod, :install_info, [
      msg,
      state.installer_state
    ])
    |> installer_resp(state)
    |> installer_progress()
    |> installer_complete()
  end

  defp installer_resp({ok, installer_state}, state) when ok in [:ok, :noreply] do
    {:noreply, %{state | installer_state: installer_state}}
  end

  defp installer_resp({:stop, reason, installer_state}, state) do
    {:stop, reason, %{state | installer_state: installer_state}}
  end

  defp installer_resp({:error, reason, installer_state}, state) do
    {:stop, reason, %{state | installer_state: installer_state}}
  end

  defp installer_complete({:stop, :normal, state}) do
    Logger.debug("Installer [#{state.binary_metadata.prn}]: complete")
    Binary.stamp_installed(state.cache_pid, state.binary_metadata)
    Binary.put_kv_installed(state.kv_pid, state.binary_metadata, :progress)
    try_send(state.callback, {Installer, state.binary_metadata.prn, :complete})
    {:stop, :normal, state}
  end

  defp installer_complete({:noreply, state}) do
    {:noreply, state}
  end

  defp installer_complete({:stop, error, state}) do
    Logger.error("Installer [#{state.binary_metadata.prn}]: error #{inspect(error)}")
    try_send(state.callback, {Installer, state.binary_metadata.prn, {:error, error}})
    {:stop, :normal, state}
  end

  defp installer_progress({:noreply, state}) do
    download_percent =
      case state.source do
        :cache -> 1.0
        :download -> state.install_percent
      end

    try_send(
      state.callback,
      {Installer, state.binary_metadata.prn,
       {:progress, {download_percent, state.install_percent}}}
    )

    {:noreply, state}
  end

  defp installer_progress({:stop, error, state}) do
    Logger.error("Installer [#{state.binary_metadata.prn}]: error #{inspect(error)}")
    try_send(state.callback, {Installer, state.binary_metadata.prn, {:error, error}})
    {:stop, :normal, state}
  end

  defp installer_error({:stop, error, state}) do
    Logger.error("Installer [#{state.binary_metadata.prn}]: error #{inspect(error)}")
    try_send(state.callback, {Installer, state.binary_metadata.prn, {:error, error}})
    {:stop, :normal, state}
  end

  defp installer_mod(%Binary{custom_metadata: %{"peridiod" => %{"installer" => "cache"}}}),
    do: Installer.Cache

  defp installer_mod(%Binary{custom_metadata: %{"peridiod" => %{"installer" => "fwup"}}}),
    do: Installer.Fwup

  defp installer_mod(%Binary{custom_metadata: %{"peridiod" => %{"installer" => "file"}}}),
    do: Installer.File

  defp installer_mod(%Binary{custom_metadata: %{"peridiod" => %{"installer" => "deb"}}}),
    do: Installer.Deb

  defp installer_mod(%Binary{custom_metadata: %{"peridiod" => %{"installer" => "rpm"}}}),
    do: Installer.Rpm

  defp installer_mod(%Binary{custom_metadata: %{"peridiod" => %{"installer" => "opkg"}}}),
    do: Installer.Opkg

  defp installer_mod(%Binary{custom_metadata: %{"peridiod" => %{"installer" => "swupdate"}}}),
    do: Installer.SWUpdate

  defp do_install_from_cache(state) do
    cache_file = Binary.cache_file(state.binary_metadata)
    send(self(), {:cache_install, :start})
    installer_pid = self()

    Task.start(fn ->
      Cache.read_stream(state.cache_pid, cache_file)
      |> Enum.map(&send(installer_pid, {:cache_install, :update, &1}))
    end)
  end

  defp do_install_from_download(state) do
    downloader_mod =
      apply(state.installer_mod, :install_downloader, [
        state.binary_metadata,
        state.installer_opts
      ])

    do_install_from_download_mod(downloader_mod, state)
  end

  defp do_install_from_download_mod(StreamDownloader, state) do
    pid = self()
    send(self(), {:download_stream, :start})
    fun = &send(pid, {:download_stream, &1})

    {:ok, _downloader} =
      StreamDownloader.Supervisor.start_child(
        state.binary_metadata.prn,
        state.binary_metadata.uri,
        fun
      )
  end

  defp do_install_from_download_mod(CacheDownloader, state) do
    send(self(), {:download_cache, :start})

    {:ok, _downloader} =
      CacheDownloader.Supervisor.start_child(
        state.binary_metadata,
        %{config: state.config, cache_pid: state.cache_pid}
      )
  end

  defp try_send(nil, _msg), do: :ok

  defp try_send(pid, msg) do
    if Process.alive?(pid) do
      send(pid, msg)
    end
  end
end

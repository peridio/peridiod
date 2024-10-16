defmodule Peridiod.Release.Server do
  @moduledoc """
  Release Server polls the Peridio Device API for updates.

  When the device is told to update, it will receive release information and a
  manifest of [{artifact, artifact_version, binary}] info. The update is applied
  according to the following workflow.

  For required binaries:
  * Validate artifact signatures' public key values are trusted by local key store.
  * Initialize a Download with an Installer
  * Begin Download (Download Started Event)
  * Download chunks (Download Progress Events)
  * Finish Download (Download Finished Event)
  * Validate hash (during stream)
  * Installer applied (Binary Applied)
  * Update release artifact status to complete
  """
  use GenServer

  require Logger

  alias Peridiod.{Binary, SigningKey, Socket, Release}
  alias Peridiod.Binary.{Installer, CacheDownloader}
  alias PeridiodPersistence.KV

  @update_poll_interval 30 * 60 * 1000
  @progress_message_interval 1500

  @doc false
  @spec start_link(any(), any()) :: GenServer.on_start()
  def start_link(config, genserver_opts \\ [name: __MODULE__]) do
    GenServer.start_link(__MODULE__, config, genserver_opts)
  end

  def stop(pid_or_name \\ __MODULE__) do
    GenServer.stop(pid_or_name)
  end

  def check_for_update(pid_or_name \\ __MODULE__) do
    GenServer.call(pid_or_name, :check_for_update)
  end

  def current_release(pid_or_name \\ __MODULE__) do
    GenServer.call(pid_or_name, :current_release)
  end

  def cache_release(pid_or_name \\ __MODULE__, %Release{} = release_metadata) do
    GenServer.call(pid_or_name, {:cache_release, release_metadata})
  end

  def install_release(pid_or_name \\ __MODULE__, %Release{} = release_metadata) do
    GenServer.call(pid_or_name, {:install_release, release_metadata})
  end

  def cache_binary(pid_or_name \\ __MODULE__, %Binary{} = binary_metadata) do
    GenServer.call(pid_or_name, {:cache_binary, binary_metadata})
  end

  def install_binary(pid_or_name \\ __MODULE__, %Binary{} = binary_metadata) do
    GenServer.call(pid_or_name, {:install_binary, binary_metadata})
  end

  def add_trusted_signing_key(pid_or_name \\ __MODULE__, %SigningKey{} = signing_key) do
    GenServer.call(pid_or_name, {:add_trusted_signing_key, signing_key})
  end

  def remove_trusted_signing_key(pid_or_name \\ __MODULE__, %SigningKey{} = signing_key) do
    GenServer.call(pid_or_name, {:remove_trusted_signing_key, signing_key})
  end

  @impl GenServer
  def init(config) do
    trusted_signing_keys =
      config.trusted_signing_keys
      |> load_trusted_signing_keys()

    cache_pid = config.cache_pid
    kv_pid = config.kv_pid
    poll_interval = config.release_poll_interval || @update_poll_interval
    progress_message_interval = @progress_message_interval

    current_release_prn =
      case KV.get("peridio_rel_current") do
        "" -> nil
        peridio_rel_current -> peridio_rel_current
      end

    current_release_version =
      case KV.get("peridio_vsn_current") do
        "" -> KV.get_active("peridio_version")
        peridio_vsn_current -> peridio_vsn_current
      end

    progress_release_prn =
      case KV.get("peridio_rel_progress") do
        "" -> nil
        peridio_rel_progress -> peridio_rel_progress
      end

    current_release = load_release_metadata_from_cache(current_release_prn, cache_pid)
    progress_release = load_release_metadata_from_cache(progress_release_prn, cache_pid)

    sdk_client =
      config.sdk_client
      |> Map.put(:release_prn, current_release_prn)
      |> Map.put(:release_version, current_release_version)

    state = %{
      config: config,
      sdk_client: sdk_client,
      poll_interval: poll_interval,
      targets: config.targets,
      trusted_signing_keys: trusted_signing_keys,
      trusted_signing_key_threshold: config.trusted_signing_key_threshold,
      current_release: current_release,
      progress_release: progress_release,
      cache_pid: cache_pid,
      kv_pid: kv_pid,
      installing_release: nil,
      processing_binaries: %{},
      progress_message: %{},
      progress_message_interval: progress_message_interval,
      progress_message_timer: nil,
      update_timer: nil
    }

    {:ok, state, {:continue, config.release_poll_enabled}}
  end

  @impl GenServer
  def handle_continue(true, state) do
    Logger.debug("Release Polling Enabled")

    {_resp, state} =
      state
      |> update_check()
      |> update_response(state)

    progress_message_timer =
      Process.send_after(self(), :send_progress_message, state.progress_message_interval)

    update_timer = Process.send_after(self(), :check_for_update, state.poll_interval)

    {:noreply,
     %{state | progress_message_timer: progress_message_timer, update_timer: update_timer}}
  end

  def handle_continue(false, state) do
    Logger.debug("Release Polling Disabled")
    {:noreply, state}
  end

  @impl GenServer
  def handle_call(:check_for_update, _from, state) do
    {resp, state} =
      state
      |> update_check()
      |> update_response(state)

    {:reply, resp, state}
  end

  def handle_call(:current_release, _from, state) do
    {:reply, state.current_release, state}
  end

  @impl GenServer
  def handle_call({:cache_release, %Release{} = release_metadata}, {from, _ref}, state) do
    {reply, state} = do_cache_release(release_metadata, from, state)
    {:reply, reply, state}
  end

  def handle_call(
        {:install_release, %Release{} = release_metadata},
        {from, _ref},
        state
      ) do
    {reply, state} = do_install_release(release_metadata, from, state)
    {:reply, reply, state}
  end

  def handle_call(
        {:cache_binary, %Binary{prn: prn}},
        _from,
        %{processing_binaries: processing} = state
      )
      when is_map_key(processing, prn) do
    {:reply, {:error, :already_processing}, state}
  end

  def handle_call({:cache_binary, %Binary{} = binary_metadata}, {from, _ref}, state) do
    trusted? = binaries_trusted?([binary_metadata], state)
    cached? = Binary.cached?(state.cache_pid, binary_metadata)

    case {trusted?, cached?} do
      {true, false} ->
        {:reply, :ok,
         do_binaries_jobs([binary_metadata], CacheDownloader.Supervisor, from, state)}

      {false, _} ->
        {:reply, {:error, :untrusted_signatures}, state}

      {true, true} ->
        {:reply, {:error, :already_cached}, state}
    end
  end

  def handle_call(
        {:install_binary, %Binary{prn: prn}},
        _from,
        %{processing_binaries: processing} = state
      )
      when is_map_key(processing, prn) do
    {:reply, {:error, :already_processing}, state}
  end

  def handle_call({:install_binary, %Binary{} = binary_metadata}, {from, _ref}, state) do
    trusted? = binaries_trusted?([binary_metadata], state)
    installed? = Binary.installed?(state.cache_pid, binary_metadata)

    case {trusted?, installed?} do
      {true, false} ->
        {:reply, :ok, do_binaries_jobs([binary_metadata], Installer.Supervisor, from, state)}

      {false, _} ->
        {:reply, {:error, :untrusted_signatures}, state}

      {true, true} ->
        {:reply, {:error, :already_installed}, state}
    end
  end

  def handle_call({:add_trusted_signing_key, signing_key}, _from, state) do
    trusted_signing_keys = MapSet.put(state.trusted_signing_keys, signing_key)
    {:reply, {:ok, trusted_signing_keys}, %{state | trusted_signing_keys: trusted_signing_keys}}
  end

  def handle_call({:remove_trusted_signing_key, signing_key}, _from, state) do
    trusted_signing_keys = MapSet.delete(state.trusted_signing_keys, signing_key)
    {:reply, {:ok, trusted_signing_keys}, %{state | trusted_signing_keys: trusted_signing_keys}}
  end

  @impl GenServer
  def handle_info(:check_for_update, state) do
    Logger.debug("Checking for an update")

    {_, state} =
      state
      |> update_check()
      |> update_response(state)

    update_timer = Process.send_after(self(), :check_for_update, state.poll_interval)

    {:noreply, %{state | update_timer: update_timer}}
  end

  def handle_info({:download_cache, binary_metadata, {:progress, download_percent}}, state) do
    binary_progress =
      state.progress_message
      |> Map.get(binary_metadata.prn, %{download_percent: 0.0, install_percent: 0.0})
      |> Map.put(:download_percent, download_percent)

    progress_message = Map.put(state.progress_message, binary_metadata.prn, binary_progress)
    {:noreply, %{state | progress_message: progress_message}}
  end

  def handle_info({:download_cache, binary_metadata, :complete}, state) do
    try_send(
      state.processing_binaries[binary_metadata.prn][:callback],
      {__MODULE__, :download, binary_metadata.prn, :complete}
    )

    Logger.debug("Downloading to cache complete")

    Binary.stamp_cached(state.cache_pid, binary_metadata)

    state = %{
      state
      | processing_binaries: Map.delete(state.processing_binaries, binary_metadata.prn)
    }

    {:noreply, state}
  end

  def handle_info({:download_cache, binary_metadata, {:error, error}}, state) do
    try_send(
      state.processing_binaries[binary_metadata.prn][:callback],
      {__MODULE__, :download, binary_metadata.prn, {:error, error}}
    )

    Logger.error("Error downloading to cache: #{inspect(error)}")

    state = %{
      state
      | processing_binaries: Map.delete(state.processing_binaries, binary_metadata.prn)
    }

    {:noreply, state}
  end

  def handle_info(
        {Installer, binary_prn, {:progress, {download_percent, install_percent}}},
        state
      ) do
    binary_progress =
      state.progress_message
      |> Map.get(binary_prn, %{download_percent: 0.0, install_percent: 0.0})
      |> Map.put(:download_percent, download_percent)
      |> Map.put(:install_percent, install_percent)

    progress_message = Map.put(state.progress_message, binary_prn, binary_progress)
    {:noreply, %{state | progress_message: progress_message}}
  end

  def handle_info({Installer, binary_prn, :complete}, state) do
    Logger.debug("Release Server: Installer Complete")

    try_send(
      state.processing_binaries[binary_prn][:callback],
      {__MODULE__, :install, binary_prn, :complete}
    )

    progress_message =
      Map.put(state.progress_message, binary_prn, %{download_percent: 1.0, install_percent: 1.0})

    state = %{
      state
      | processing_binaries: Map.delete(state.processing_binaries, binary_prn),
        progress_message: progress_message
    }

    state = process_release(state)
    {:noreply, state}
  end

  def handle_info({Installer, binary_prn, {:error, error}}, state) do
    try_send(
      state.processing_binaries[binary_prn][:callback],
      {__MODULE__, :install, binary_prn, {:error, error}}
    )

    progress_message =
      state.progress_message
      |> Map.delete(binary_prn)

    state = %{
      state
      | processing_binaries: Map.delete(state.processing_binaries, binary_prn),
        progress_message: progress_message
    }

    {:noreply, state}
  end

  def handle_info(:send_progress_message, state) do
    Socket.send_binary_progress(state.progress_message)
    timer_ref = Process.send_after(self(), :send_progress_message, @progress_message_interval)
    {:noreply, %{state | progress_message_timer: timer_ref, progress_message: %{}}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    Enum.each(state.processing_binaries, &Process.exit(elem(&1, 1).job_pid, reason))
    :ok
  end

  defp update_check(%{sdk_client: client}) do
    Logger.debug("Do update check")

    PeridioSDK.DeviceAPI.Devices.update(client, [
      "manifest.binary_prn",
      "manifest.custom_metadata",
      "manifest.hash",
      "manifest.target",
      "manifest.url",
      "manifest.signatures",
      "manifest.size",
      "manifest.artifact.prn",
      "manifest.artifact.name",
      "manifest.artifact_version.prn",
      "manifest.artifact_version.version",
      "bundle.prn",
      "release.prn",
      "release.version",
      "release.version_requirement"
    ])
  end

  # An update is available, We should retrieve the manifest and start installing binaries
  defp update_response(
         {:ok, %{status: 200, body: %{"status" => "update"} = body}},
         state
       ) do
    # Logger.debug("Release Manager: update #{inspect(body)}")
    {:ok, release_metadata} = Release.metadata_from_manifest(body)
    Release.metadata_to_cache(state.cache_pid, release_metadata)

    case do_install_release(release_metadata, self(), state) do
      {:ok, state} ->
        Logger.info("Release Manager: Installing Update")
        {:updating, %{state | progress_release: release_metadata}}

      {{:error, error}, state} ->
        Logger.error("Release Manager: Error #{inspect(error)}")
        {:no_update, state}
    end
  end

  defp update_response({:ok, %{status: 200, body: %{"status" => "no_update"}}}, state) do
    Logger.debug("Release Manager: no update")
    {:no_update, state}
  end

  defp update_response({:error, %{reason: reason}}, state) do
    Logger.error("Release Manager: error checking for update #{inspect(reason)}")
    {:no_update, state}
  end

  defp load_trusted_signing_keys([]) do
    Logger.warning("""
      Trusted signing keys are unspecified

      You can configure Peridio to only install binaries that have been signed by
      signing keys you explicitly trust. See the peridiod configuration options for
      configuring a list of public keys.
    """)

    MapSet.new()
  end

  defp load_trusted_signing_keys(keys) when is_list(keys) do
    MapSet.new(keys)
  end

  defp do_install_release(release_metadata, callback, %{installing_release: nil} = state) do
    binaries_metadata =
      release_metadata
      |> Release.filter_binaries_by_targets(state.targets)
      |> Enum.reject(&Binary.kv_installed?(state.kv_pid, &1, :current))
      |> Enum.reject(&Binary.installed?(state.cache_pid, &1))

    trusted? = binaries_trusted?(binaries_metadata, state)

    case trusted? do
      true ->
        Logger.debug("Install Release: ok")
        Release.kv_progress(state.kv_pid, release_metadata)

        case binaries_metadata do
          [] ->
            state = %{state | installing_release: {release_metadata, binaries_metadata, callback}}
            state = finish_release(state)
            {:ok, state}

          _ ->
            state = do_binaries_jobs(binaries_metadata, Installer.Supervisor, callback, state)
            state = %{state | installing_release: {release_metadata, binaries_metadata, callback}}
            {:ok, state}
        end

      false ->
        Logger.debug("Install Release: untrusted signatures")
        {{:error, :untrusted_signatures}, state}
    end
  end

  defp do_install_release(
         release_metadata,
         _callback,
         %{installing_release: {release_metadata, _, _}} = state
       ) do
    {{:error, {:installing_release, release_metadata}}, state}
  end

  defp do_cache_release(release_metadata, callback, state) do
    binaries_metadata =
      release_metadata
      |> Release.filter_binaries_by_targets(state.targets)
      |> Enum.reject(&Binary.kv_installed?(state.kv_pid, &1, :current))
      |> Enum.reject(&Binary.cached?(state.cache_pid, &1))

    trusted? = binaries_trusted?(binaries_metadata, state)
    cached? = Release.cached?(state.cache_pid, release_metadata)

    case {trusted?, cached?} do
      {true, false} ->
        Logger.debug("Cache Release: ok")
        {:ok, do_binaries_jobs(binaries_metadata, CacheDownloader.Supervisor, callback, state)}

      {false, _} ->
        Logger.debug("Cache Release: untrusted signatures")
        {{:error, :untrusted_signatures}, state}

      {true, true} ->
        Logger.debug("Cache Release: already cached")
        {{:error, :already_cached}, state}
    end
  end

  defp do_binaries_jobs(binaries_metadata, mod, callback, state)
       when mod in [CacheDownloader.Supervisor, Installer.Supervisor] do
    processing_binaries =
      Enum.reduce(
        binaries_metadata,
        state.processing_binaries,
        fn binary_metadata, processing_binaries ->
          {:ok, job_pid} =
            mod.start_child(binary_metadata, %{config: state.config, cache_pid: state.cache_pid})

          Map.put(processing_binaries, binary_metadata.prn, %{
            job_pid: job_pid,
            callback: callback
          })
        end
      )

    %{state | processing_binaries: processing_binaries}
  end

  defp binaries_trusted?(binaries_metadata, state) do
    trusted_result =
      Enum.split_with(binaries_metadata, fn binary_metadata ->
        trusted_signing_keys =
          Binary.trusted_signing_keys(binary_metadata, state.trusted_signing_keys)

        Enum.count(trusted_signing_keys) >= state.trusted_signing_key_threshold
      end)

    case trusted_result do
      {_trusted, []} -> true
      _ -> false
    end
  end

  defp process_release(%{installing_release: nil} = state), do: state

  defp process_release(%{installing_release: {release, binaries_metadata, callback}} = state) do
    processing_binaries_prns = Map.keys(state.processing_binaries)

    remaining_binaries =
      Enum.filter(binaries_metadata, fn binary_metadata ->
        binary_metadata.prn in processing_binaries_prns
      end)

    Logger.debug(
      "Release Install processing remaining: #{inspect(Enum.count(remaining_binaries))}"
    )

    finish_release(%{state | installing_release: {release, remaining_binaries, callback}})
  end

  defp finish_release(%{installing_release: {release_metadata, [], callback}} = state) do
    Logger.info("Release Manager: Install complete")
    Release.stamp_installed(state.cache_pid, release_metadata)
    Release.kv_advance(state.kv_pid)

    version =
      case release_metadata.version do
        nil -> nil
        version -> Version.to_string(version)
      end

    sdk_client =
      state.sdk_client
      |> Map.put(:release_prn, release_metadata.prn)
      |> Map.put(:release_version, version)

    try_send(callback, {__MODULE__, :install, release_metadata.prn, :complete})

    maybe_reboot(release_metadata, callback)

    %{
      state
      | installing_release: nil,
        current_release: release_metadata,
        progress_release: nil,
        sdk_client: sdk_client
    }
  end

  defp finish_release(state), do: state

  defp load_release_metadata_from_cache(nil, _cache_pid), do: nil

  defp load_release_metadata_from_cache(release_prn, cache_pid) do
    case Release.metadata_from_cache(cache_pid, release_prn) do
      {:ok, release} -> release
      _ -> nil
    end
  end

  defp maybe_reboot(%Release{binaries: binaries} = release_metadata, callback) do
    reboot? =
      Enum.any?(binaries, fn %Binary{custom_metadata: custom_metadata} ->
        case custom_metadata["peridiod"]["reboot_required"] do
          true -> true
          _ -> false
        end
      end)

    if reboot? do
      try_send(callback, {__MODULE__, :install, release_metadata.prn, :reboot})

      if Peridiod.env() != :test do
        System.cmd("reboot", [], stderr_to_stdout: true)
      end
    end
  end

  defp try_send(nil, _msg), do: :ok

  defp try_send(pid, msg) do
    if Process.alive?(pid) do
      send(pid, msg)
    end
  end
end

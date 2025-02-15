defmodule Peridiod.Update.Server do
  @moduledoc """
  Update Server polls the Peridio Device API for updates.

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
  * Update binary to installed
  """
  use GenServer

  require Logger

  alias Peridiod.{
    Binary,
    SigningKey,
    Cloud.Socket,
    Release,
    Bundle,
    BundleOverride,
    Update,
    Cloud
  }

  alias Peridiod.Binary.{Installer, CacheDownloader}
  alias PeridiodPersistence.KV

  @progress_message_interval 1500

  @doc false
  @spec start_link(any(), any()) :: GenServer.on_start()
  def start_link(config, genserver_opts \\ [name: __MODULE__]) do
    GenServer.start_link(__MODULE__, config, genserver_opts)
  end

  def stop(pid_or_name \\ __MODULE__) do
    GenServer.stop(pid_or_name)
  end

  @spec current_bundle(pid() | atom()) :: {BundleOverride.t() | Release.t()}
  def current_bundle(pid_or_name \\ __MODULE__) do
    GenServer.call(pid_or_name, :current_bundle)
  end

  def cache_bundle(pid_or_name \\ __MODULE__, %Bundle{} = bundle_metadata) do
    GenServer.call(pid_or_name, {:cache_bundle, bundle_metadata})
  end

  def install_bundle(pid_or_name \\ __MODULE__, bundle_or_via_metadata) do
    GenServer.call(pid_or_name, {:install_bundle, bundle_or_via_metadata})
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

  def reboot(pid_or_name \\ __MODULE__) do
    GenServer.call(pid_or_name, :reboot)
  end

  @impl GenServer
  def init(config) do
    trusted_signing_keys =
      config.trusted_signing_keys
      |> load_trusted_signing_keys()

    cache_pid = config.cache_pid
    kv_pid = config.kv_pid
    progress_message_interval = @progress_message_interval

    current_via_prn =
      case KV.get("peridio_via_current") do
        nil -> KV.get("peridio_rel_current")
        "" -> nil
        val -> val
      end

    current_bundle_prn = KV.get("peridio_bun_current")

    case KV.get("peridio_bun_current") do
      nil -> nil
      "" -> nil
      val -> val
    end

    progress_via_prn =
      case KV.get("peridio_via_progress") do
        nil -> nil
        "" -> nil
        val -> val
      end

    progress_bundle_prn =
      case KV.get("peridio_bun_progress") do
        nil -> nil
        "" -> nil
        val -> val
      end

    current_via = load_metadata_from_cache(current_via_prn, cache_pid)
    current_bundle = load_metadata_from_cache(current_bundle_prn, cache_pid)
    progress_via = load_metadata_from_cache(progress_via_prn, cache_pid)
    progress_bundle = load_metadata_from_cache(progress_bundle_prn, cache_pid)

    state = %{
      config: config,
      targets: config.targets,
      trusted_signing_keys: trusted_signing_keys,
      trusted_signing_key_threshold: config.trusted_signing_key_threshold,
      current_via: current_via,
      current_bundle: current_bundle,
      progress_via: progress_via,
      progress_bundle: progress_bundle,
      cache_pid: cache_pid,
      kv_pid: kv_pid,
      installing_bundle: nil,
      processing_binaries: %{},
      progress_message: %{},
      progress_message_interval: progress_message_interval,
      progress_message_timer: nil,
      reboot_timer: nil,
      update_timer: nil
    }

    {:ok, state}
  end

  def handle_call(:current_bundle, _from, state) do
    {:reply, {state.current_bundle, state.current_via}, state}
  end

  @impl GenServer
  def handle_call({:cache_bundle, %Bundle{} = bundle_metadata}, {from, _ref}, state) do
    {reply, state} = do_cache_bundle(bundle_metadata, from, state)
    {:reply, reply, state}
  end

  def handle_call(
        {:install_bundle, bundle_or_via_metadata},
        {from, _ref},
        state
      ) do
    {reply, state} = do_install_bundle(bundle_or_via_metadata, from, state)
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

  def handle_call(:reboot, _from, state) do
    state = do_reboot(state)
    {:reply, :ok, state}
  end

  @impl GenServer
  def handle_info(:resume_update, %{progress_bundle: nil} = state) do
    Logger.info("[Update Server] No update to resume")
    Update.kv_progress_reset_boot_count(state.kv_pid)
    {:noreply, state}
  end

  def handle_info(:resume_update, %{progress_bundle: bundle_metadata} = state) do
    Logger.info("[Update Server] Resuming bundle install")
    max_boot_count = state.config.update_resume_max_boot_count

    with {:ok, boot_count} <- Update.kv_progress_increment_boot_count(state.kv_pid),
         {boot_count, _} <- Integer.parse(boot_count),
         true <- boot_count < max_boot_count do
      case do_install_bundle(bundle_metadata, self(), state) do
        {:ok, state} ->
          Logger.info("[Update Server] Resuming installing bundle #{bundle_metadata.prn}")
          {:noreply, state}

        {{:error, error}, state} ->
          Logger.error(
            "[Update Server] Error resuming installing bundle #{bundle_metadata.prn} #{inspect(error)}"
          )

          {:noreply, state}
      end
    else
      false ->
        Update.kv_progress_reset(state.kv_pid)
        Logger.error("[Update Server] Resume max boot_count reached. Aborting installation")
        {:noreply, %{state | progress_bundle: nil, progress_via: nil}}

      _ ->
        Update.kv_progress_reset(state.kv_pid)
        Logger.error("[Update Server] Aborting resumption")
        {:noreply, %{state | progress_bundle: nil, progress_via: nil}}
    end
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

    Logger.error("[Update Server] Error downloading to cache: #{inspect(error)}")

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

    state = process_bundle(state)
    {:noreply, state}
  end

  def handle_info({Installer, binary_prn, {:error, reason}}, state) do
    try_send(
      state.processing_binaries[binary_prn][:callback],
      {__MODULE__, :install, binary_prn, {:error, reason}}
    )

    progress_message =
      state.progress_message
      |> Map.delete(binary_prn)

    processing_binary =
      Map.get(state.processing_binaries, binary_prn, %{binary_prn => %{status: {:error, reason}}})
      |> Map.put(:status, {:error, reason})

    state = %{
      state
      | processing_binaries: Map.put(state.processing_binaries, binary_prn, processing_binary),
        progress_message: progress_message
    }

    state = process_bundle(state)
    {:noreply, state}
  end

  def handle_info(:send_progress_message, state) do
    Socket.send_binary_progress(state.progress_message)
    timer_ref = Process.send_after(self(), :send_progress_message, @progress_message_interval)
    {:noreply, %{state | progress_message_timer: timer_ref, progress_message: %{}}}
  end

  def handle_info(msg, state) do
    Logger.warning("[Update Server] Unhandled message #{inspect(msg)}")
    {:noreply, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    Enum.each(state.processing_binaries, fn
      {_, %{job_pid: pid}} -> Process.exit(pid, reason)
      _ -> :noop
    end)

    :ok
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

  defp do_install_bundle(%Release{} = via_metadata, callback, state) do
    do_install_bundle(via_metadata.bundle, via_metadata, callback, state)
  end

  defp do_install_bundle(%BundleOverride{} = via_metadata, callback, state) do
    do_install_bundle(via_metadata.bundle, via_metadata, callback, state)
  end

  defp do_install_bundle(%Bundle{} = bundle_metadata, callback, state) do
    do_install_bundle(bundle_metadata, nil, callback, state)
  end

  defp do_install_bundle(
         _bundle,
         _via,
         _callback,
         %{installing_bundle: {bundle_metadata, _, _}} = state
       ) do
    Logger.error(
      "[Update Server] Error installing while bundle #{bundle_metadata.prn} is being installed"
    )

    {{:error, {:installing_bundle, bundle_metadata}}, state}
  end

  defp do_install_bundle(
         bundle_metadata,
         via_metadata,
         callback,
         %{installing_bundle: nil} = state
       ) do
    binaries_metadata =
      Bundle.filter_uninstalled_binaries_by_target(bundle_metadata, state.targets,
        cache_pid: state.cache_pid,
        kv_pid: state.kv_pid
      )

    binaries_metadata =
      case binaries_metadata do
        {:ok, binaries_metadata} ->
          binaries_metadata

        {:error, :no_targets} ->
          Logger.info(
            "[Update Server] No binaries to install because there are no binaries for supported targets #{inspect(state.targets)}"
          )

          []

        {:error, :kv_installed} ->
          Logger.info(
            "[Update Server] No binaries to install because binaries already reported installed in peridio_kv_installed"
          )

          []

        {:error, :cache_installed} ->
          Logger.info(
            "[Update Server] No binaries to install because binaries already reported installed in cache data"
          )

          []
      end

    trusted? = binaries_trusted?(binaries_metadata, state)

    case trusted? do
      true ->
        Update.kv_progress(state.kv_pid, bundle_metadata, state.progress_via)

        case binaries_metadata do
          [] ->
            Logger.warning("Bundle binaries list resolved empty.")

            state = %{state | installing_bundle: {bundle_metadata, binaries_metadata, callback}}
            state = finish_bundle(state)
            {:ok, state}

          _ ->
            state = do_binaries_jobs(binaries_metadata, Installer.Supervisor, callback, state)

            state = %{
              state
              | installing_bundle: {bundle_metadata, binaries_metadata, callback},
                progress_via: via_metadata
            }

            {:ok, state}
        end

      false ->
        Logger.error("[Update Server] unable to install binaries with untrusted signatures")
        {{:error, :untrusted_signatures}, state}
    end
  end

  defp do_cache_bundle(bundle_metadata, callback, state) do
    binaries_metadata =
      bundle_metadata
      |> Bundle.filter_binaries_by_targets(state.targets)
      |> Enum.reject(&Binary.kv_installed?(state.kv_pid, &1, :current))
      |> Enum.reject(&Binary.cached?(state.cache_pid, &1))

    trusted? = binaries_trusted?(binaries_metadata, state)
    cached? = Bundle.cached?(state.cache_pid, bundle_metadata)

    case {trusted?, cached?} do
      {true, false} ->
        Logger.info("[Update Server] Caching bundle #{bundle_metadata.prn}")
        {:ok, do_binaries_jobs(binaries_metadata, CacheDownloader.Supervisor, callback, state)}

      {false, _} ->
        Logger.error("[Update Server] Unable to cache bundle due to untrusted signatures")
        {{:error, :untrusted_signatures}, state}

      {true, true} ->
        Logger.info("[Update Server] Bundle #{bundle_metadata.prn} already cached")
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
            mod.start_child(binary_metadata, %{
              config: state.config,
              cache_pid: state.cache_pid,
              kv_pid: state.kv_pid
            })

          Map.put(processing_binaries, binary_metadata.prn, %{
            job_pid: job_pid,
            callback: callback,
            status: :ok
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

  defp process_bundle(%{installing_bundle: nil} = state), do: state

  defp process_bundle(
         %{installing_bundle: {bundle_metadata, binaries_metadata, callback}} = state
       ) do
    processing_binaries_prns = Map.keys(state.processing_binaries)

    remaining_binaries =
      Enum.filter(binaries_metadata, fn binary_metadata ->
        binary_metadata.prn in processing_binaries_prns
      end)

    Logger.info(
      "[Update Server] Bundle install processing remaining: #{inspect(Enum.count(remaining_binaries))}"
    )

    finish_bundle(%{state | installing_bundle: {bundle_metadata, remaining_binaries, callback}})
  end

  defp finish_bundle(%{installing_bundle: {bundle_metadata, [], callback}} = state) do
    via_metadata = state.progress_via || %{}

    version =
      case Map.get(via_metadata, :version) do
        nil -> ""
        version -> Version.to_string(version)
      end

    case via_metadata do
      %Release{} -> Release.stamp_installed(state.cache_pid, via_metadata)
      %BundleOverride{} -> BundleOverride.stamp_installed(state.cache_pid, via_metadata)
      _ -> :noop
    end

    Bundle.stamp_installed(state.cache_pid, bundle_metadata)
    Update.kv_advance(state.kv_pid)

    Update.cache_clean(state.cache_pid, KV.get_all(state.kv_pid))
    Logger.info("[Update Server] Install complete")

    Cloud.update_client_headers(
      bundle_prn: bundle_metadata.prn,
      via_prn: Map.get(via_metadata, :prn),
      release_version: version
    )

    try_send(callback, {__MODULE__, :install, bundle_metadata.prn, :complete})
    state = maybe_reboot(bundle_metadata, callback, state)

    %{
      state
      | installing_bundle: nil,
        current_bundle: state.progress_bundle,
        current_via: via_metadata,
        progress_bundle: nil,
        progress_via: nil
    }
  end

  defp finish_bundle(
         %{installing_bundle: {_bundle_metadata, _remaining_binaries, _callback}} = state
       ) do
    result =
      Enum.split_with(state.processing_binaries, fn
        {_, %{status: {:error, _reason}}} ->
          true

        {_, _} ->
          false
      end)

    case result do
      {[], _} ->
        state

      {[_ | _], _} ->
        Logger.error("[Update Server] Install error. stopping release")
        Update.kv_progress_reset(state.kv_pid)

        %{
          state
          | installing_bundle: nil,
            processing_binaries: %{},
            progress_bundle: nil,
            progress_message: %{},
            progress_via: nil
        }
    end
  end

  defp finish_bundle(state), do: state

  defp load_metadata_from_cache(nil, _cache_pid), do: nil

  defp load_metadata_from_cache(prn, cache_pid) do
    case Bundle.via(prn) do
      Release ->
        case Release.metadata_from_cache(cache_pid, prn) do
          {:ok, release} -> release
          _ -> nil
        end

      BundleOverride ->
        case BundleOverride.metadata_from_cache(cache_pid, prn) do
          {:ok, override} -> override
          _ -> nil
        end

      Bundle ->
        case Bundle.metadata_from_cache(cache_pid, prn) do
          {:ok, bundle} -> bundle
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp maybe_reboot(%Bundle{binaries: binaries} = bundle_metadata, callback, state) do
    reboot? =
      Enum.any?(binaries, fn %Binary{custom_metadata: custom_metadata} ->
        case custom_metadata["peridiod"]["reboot_required"] do
          true -> true
          _ -> false
        end
      end)

    case reboot? do
      true ->
        try_send(callback, {__MODULE__, :install, bundle_metadata.prn, :reboot})
        do_reboot(state)

      false ->
        state
    end
  end

  defp do_reboot(state) do
    reboot_timer =
      case Peridiod.env_test?() do
        true ->
          nil

        false ->
          delay = state.config.reboot_delay
          Logger.info("[Update Server] Rebooting in #{delay} ms ")
          :timer.apply_after(delay, Update, :system_reboot, [state.config])
      end

    %{state | reboot_timer: reboot_timer}
  end

  defp try_send(nil, _msg), do: :ok

  defp try_send(pid, msg) do
    if self() != pid and Process.alive?(pid) do
      send(pid, msg)
    end
  end
end

defmodule Peridiod.Bundle.Server do
  @moduledoc """
  Manage Bundles installation

  * Install or cache Bundles, BundleOverrides, and Releases.
  * Install or cache Optional Binaries
  """
  use GenServer

  require Logger

  alias Peridiod.{
    Binary,
    SigningKey,
    Release,
    Bundle,
    BundleOverride,
    State,
    Plan
  }

  alias PeridiodPersistence.KV

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

  @spec cache_bundle(pid() | atom(), Bundle.t()) :: :ok | {:error, any}
  def cache_bundle(pid_or_name \\ __MODULE__, %Bundle{} = bundle_metadata) do
    GenServer.call(pid_or_name, {:cache_bundle, bundle_metadata})
  end

  def install_bundle(pid_or_name \\ __MODULE__, bundle_or_via_metadata) do
    GenServer.call(pid_or_name, {:install_bundle, bundle_or_via_metadata})
  end

  @spec cache_binary(pid() | atom(), Binary.t()) :: :ok | {:error, any}
  def cache_binary(pid_or_name \\ __MODULE__, %Binary{} = binary_metadata) do
    GenServer.call(pid_or_name, {:cache_binary, binary_metadata})
  end

  @spec install_binary(pid() | atom(), Binary.t()) :: :ok | {:error, any}
  def install_binary(pid_or_name \\ __MODULE__, %Binary{} = binary_metadata) do
    GenServer.call(pid_or_name, {:install_binary, binary_metadata})
  end

  @spec add_trusted_signing_key(pid() | atom(), SigningKey.t()) :: :ok | {:error, any}
  def add_trusted_signing_key(pid_or_name \\ __MODULE__, %SigningKey{} = signing_key) do
    GenServer.call(pid_or_name, {:add_trusted_signing_key, signing_key})
  end

  @spec remove_trusted_signing_key(pid() | atom(), SigningKey.t()) :: :ok | {:error, any}
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
      callback: nil,
      plan_server_pid: config.plan_server_pid
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:current_bundle, _from, state) do
    {:reply, {state.current_bundle, state.current_via}, state}
  end

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

  def handle_call({:cache_binary, %Binary{} = binary_metadata}, {from, _ref}, state) do
    trusted? = binaries_trusted?([binary_metadata], state)
    cached? = Binary.cached?(state.cache_pid, binary_metadata)

    case {trusted?, cached?} do
      {true, false} ->
        plan_opts = [cache_pid: state.cache_pid, kv_pid: state.kv_pid]
        plan = Plan.resolve_cache_binaries([binary_metadata], plan_opts)
        {:reply, Plan.Server.execute_plan(state.plan_server_pid, plan), %{state | callback: from}}

      {false, _} ->
        {:reply, {:error, :untrusted_signatures}, state}

      {true, true} ->
        {:reply, {:error, :already_cached}, state}
    end
  end

  def handle_call({:install_binary, %Binary{} = binary_metadata}, {from, _ref}, state) do
    trusted? = binaries_trusted?([binary_metadata], state)
    installed? = Binary.installed?(state.cache_pid, binary_metadata)

    case {trusted?, installed?} do
      {true, false} ->
        plan_opts = [cache_pid: state.cache_pid, kv_pid: state.kv_pid]
        plan = Plan.resolve_install_binaries([binary_metadata], plan_opts)
        {:reply, Plan.Server.execute_plan(state.plan_server_pid, plan), %{state | callback: from}}

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
  def handle_info(:resume_update, %{progress_bundle: nil} = state) do
    Logger.info("[Bundle Server] No update to resume")
    State.progress_reset_boot_count(state.kv_pid)
    {:noreply, state}
  end

  def handle_info(:resume_update, %{progress_bundle: bundle_metadata} = state) do
    Logger.info("[Bundle Server] Resuming bundle install")
    max_boot_count = state.config.update_resume_max_boot_count

    with {:ok, boot_count} <- State.progress_increment_boot_count(state.kv_pid),
         {boot_count, _} <- Integer.parse(boot_count),
         true <- boot_count < max_boot_count do
      case do_install_bundle(bundle_metadata, self(), state) do
        {:ok, state} ->
          Logger.info("[Bundle Server] Resuming installing bundle #{bundle_metadata.prn}")
          {:noreply, state}

        {{:error, error}, state} ->
          Logger.error(
            "[Bundle Server] Error resuming installing bundle #{bundle_metadata.prn} #{inspect(error)}"
          )

          {:noreply, state}
      end
    else
      false ->
        State.progress_reset(state.kv_pid)
        Logger.error("[Bundle Server] Resume max boot_count reached. Aborting installation")
        {:noreply, %{state | progress_bundle: nil, progress_via: nil}}

      _ ->
        State.progress_reset(state.kv_pid)
        Logger.error("[Bundle Server] Aborting resumption")
        {:noreply, %{state | progress_bundle: nil, progress_via: nil}}
    end
  end

  def handle_info({Plan.Server, _pid, resp}, state) do
    try_send(state.callback, resp)
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("[Bundle Server] Unhandled message #{inspect(msg)}")
    {:noreply, state}
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
         bundle_metadata,
         via_metadata,
         callback,
         state
       ) do
    {installed_binaries, uninstalled_binaries} =
      Bundle.split_uninstalled_binaries_by_target(bundle_metadata, state.targets,
        cache_pid: state.cache_pid,
        kv_pid: state.kv_pid
      )

    case {installed_binaries, uninstalled_binaries} do
      {[], []} ->
        Logger.info(
          "[Bundle Server] No binaries to install because there are no binaries for supported targets #{inspect(state.targets)}"
        )

      {[_ | _], []} ->
        Logger.info(
          "[Bundle Server] No binaries to install because binaries already reported installed"
        )

      _ ->
        :ok
    end

    trusted? = binaries_trusted?(uninstalled_binaries, state)

    case trusted? do
      true ->
        plan_opts = [
          cache_pid: state.cache_pid,
          kv_pid: state.kv_pid,
          filtered_binaries: uninstalled_binaries,
          installed_binaries: installed_binaries
        ]

        metadata = via_metadata || bundle_metadata
        plan = Plan.resolve_install_bundle(metadata, plan_opts)
        {Plan.Server.execute_plan(state.plan_server_pid, plan), %{state | callback: callback}}

      false ->
        Logger.error("[Bundle Server] unable to install binaries with untrusted signatures")
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
        Logger.info("[Bundle Server] Caching bundle #{bundle_metadata.prn}")

        plan_opts = [
          cache_pid: state.cache_pid,
          kv_pid: state.kv_pid,
          filtered_binaries: binaries_metadata
        ]

        plan = Plan.resolve_cache_bundle(bundle_metadata, plan_opts)
        {Plan.Server.execute_plan(state.plan_server_pid, plan), %{state | callback: callback}}

      {false, _} ->
        Logger.error("[Bundle Server] Unable to cache bundle due to untrusted signatures")
        {{:error, :untrusted_signatures}, state}

      {true, true} ->
        Logger.info("[Bundle Server] Bundle #{bundle_metadata.prn} already cached")
        {{:error, :already_cached}, state}
    end
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

  defp try_send(nil, _msg), do: :ok

  defp try_send(pid, msg) do
    if self() != pid and Process.alive?(pid) do
      send(pid, {__MODULE__, self(), msg})
    end
  end
end

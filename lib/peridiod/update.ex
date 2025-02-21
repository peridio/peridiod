defmodule Peridiod.Update do
  alias Peridiod.{Release, BundleOverride, Bundle, Binary, Cache, Config}
  alias PeridiodPersistence.KV

  require Logger

  def kv_progress_reset_boot_count(kv_pid \\ KV), do: KV.put(kv_pid, "peridio_bc_progress", "0")

  def kv_progress_increment_boot_count(kv_pid \\ KV) do
    result =
      KV.get_and_update(kv_pid, "peridio_bc_progress", fn
        "" ->
          "1"

        nil ->
          "1"

        value ->
          case Integer.parse(value) do
            {value, _rem} ->
              new_value = value + 1
              Logger.info("[Update] Incrementing peridio_bc_progress #{new_value}")
              new_value |> to_string()

            _ ->
              Logger.error(
                "[Update] Error parsing peridio_bc_progress #{inspect(value)} resetting to 1"
              )

              "1"
          end
      end)

    case result do
      {:ok, %{contents: %{"peridio_bc_progress" => boot_count}}} -> {:ok, boot_count}
      error -> error
    end
  end

  def kv_progress(kv_pid \\ KV, bundle_metadata, via_metadata) do
    via_metadata = via_metadata || %{}

    version =
      case Map.get(via_metadata, :version) do
        nil -> ""
        version -> Version.to_string(version)
      end

    KV.put_map(kv_pid, %{
      "peridio_via_progress" => Map.get(via_metadata, :prn, ""),
      "peridio_bun_progress" => bundle_metadata.prn,
      "peridio_vsn_progress" => version,
      "peridio_bc_progress" => "0"
    })
  end

  def kv_progress_reset(kv_pid \\ KV) do
    KV.put_map(kv_pid, %{
      "peridio_via_progress" => "",
      "peridio_bun_progress" => "",
      "peridio_vsn_progress" => "",
      "peridio_bc_progress" => "0"
    })
  end

  def kv_advance(kv_pid \\ KV) do
    KV.reinitialize(kv_pid)

    KV.get_all_and_update(kv_pid, fn kv ->
      via_progress = Map.get(kv, "peridio_via_progress", "")
      bun_progress = Map.get(kv, "peridio_bun_progress", "")
      vsn_progress = Map.get(kv, "peridio_vsn_progress", "")
      bin_progress = Map.get(kv, "peridio_bin_progress", "")

      via_current = Map.get(kv, "peridio_via_current", "")
      bun_current = Map.get(kv, "peridio_bun_current", "")
      vsn_current = Map.get(kv, "peridio_vsn_current", "")
      bin_current = Map.get(kv, "peridio_bin_current", "")

      kv
      |> Map.put("peridio_via_previous", via_current)
      |> Map.put("peridio_bun_previous", bun_current)
      |> Map.put("peridio_vsn_previous", vsn_current)
      |> Map.put("peridio_bin_previous", bin_current)
      |> Map.put("peridio_via_current", via_progress)
      |> Map.put("peridio_bun_current", bun_progress)
      |> Map.put("peridio_vsn_current", vsn_progress)
      |> Map.put("peridio_bin_current", bin_progress)
      |> Map.put("peridio_via_progress", "")
      |> Map.put("peridio_bun_progress", "")
      |> Map.put("peridio_vsn_progress", "")
      |> Map.put("peridio_bin_progress", "")
      |> Map.put("peridio_bc_progress", "0")
    end)
  end

  def cache_clean(cache_pid \\ Cache, kv) do
    Logger.info("[Update] Cache cleanup started")
    via_current = Map.get(kv, "peridio_via_current") |> kv_sanitize()
    bun_current = Map.get(kv, "peridio_bun_current") |> kv_sanitize()
    via_previous = Map.get(kv, "peridio_via_previous") |> kv_sanitize()
    bun_previous = Map.get(kv, "peridio_bun_previous") |> kv_sanitize()

    previous_binary_prns = binary_prns_for_bundle_prn(cache_pid, bun_previous)
    current_binary_prns = binary_prns_for_bundle_prn(cache_pid, bun_current)

    relevant_via_prns = [via_current, via_previous] |> Enum.reject(&is_nil/1)
    relevant_bundle_prns = [bun_current, bun_previous] |> Enum.reject(&is_nil/1)
    relevant_binary_prns = Enum.uniq(current_binary_prns ++ previous_binary_prns)

    binary_cache_path = Binary.cache_path()
    release_cache_path = Release.cache_path()
    override_cache_path = BundleOverride.cache_path()
    bundle_cache_path = Bundle.cache_path()

    remove_binaries =
      cache_reject_relevant_prns(cache_pid, binary_cache_path, relevant_binary_prns)

    remove_releases = cache_reject_relevant_prns(cache_pid, release_cache_path, relevant_via_prns)

    remove_overrides =
      cache_reject_relevant_prns(cache_pid, override_cache_path, relevant_via_prns)

    remove_bundles =
      cache_reject_relevant_prns(cache_pid, bundle_cache_path, relevant_bundle_prns)

    remove = remove_binaries ++ remove_releases ++ remove_overrides ++ remove_bundles

    Enum.each(remove, fn path ->
      case Cache.rm_rf(cache_pid, path) do
        {:ok, _path} ->
          Logger.info("[Update] Cache cleanup removed #{inspect(path)}")

        {:error, error} ->
          Logger.error("[Update] Cache cleanup error removing #{path} #{inspect(error)}")
      end
    end)

    Logger.info("[Update] Cache cleanup finished")
  end

  def system_reboot(%Config{} = config) do
    with {_, 0} <-
           System.cmd(config.reboot_sync_cmd, config.reboot_sync_opts, stderr_to_stdout: true),
         {_, 0} <- System.cmd(config.reboot_cmd, config.reboot_opts, stderr_to_stdout: true) do
    else
      {result, code} ->
        Logger.error(
          "[Update] Exit code #{inspect(code)} while attempting to reboot the system #{inspect(result)}"
        )
    end
  end

  defp kv_sanitize(""), do: nil
  defp kv_sanitize(val), do: val

  defp binary_prns_for_bundle_prn(_cache_pid, nil) do
    []
  end

  defp binary_prns_for_bundle_prn(cache_pid, bundle_prn) do
    case Bundle.metadata_from_cache(cache_pid, bundle_prn) do
      {:ok, bundle} -> Enum.map(bundle.binaries, &Binary.cache_prn/1)
      _ -> []
    end
  end

  defp cache_reject_relevant_prns(cache_pid, cache_path, relevant_prns) do
    reject_prns =
      case Cache.ls(cache_pid, cache_path) do
        {:ok, prns} ->
          Enum.reject(prns, &(&1 in relevant_prns))

        _ ->
          []
      end

    Enum.map(reject_prns, &Path.join(cache_path, &1))
  end
end

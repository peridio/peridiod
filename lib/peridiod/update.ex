defmodule Peridiod.Update do
  alias Peridiod.{Release, BundleOverride, Bundle}
  alias PeridiodPersistence.KV

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
      "peridio_vsn_progress" => version
    })
  end

  def kv_advance(kv_pid \\ KV) do
    KV.reinitialize(kv_pid)

    KV.get_all_and_update(kv_pid, fn kv ->
      src_progress = Map.get(kv, "peridio_via_progress", "")
      bun_progress = Map.get(kv, "peridio_bun_progress", "")
      vsn_progress = Map.get(kv, "peridio_vsn_progress", "")
      bin_progress = Map.get(kv, "peridio_bin_progress", "")

      src_current = Map.get(kv, "peridio_via_current", "")
      bun_current = Map.get(kv, "peridio_bun_current", "")
      vsn_current = Map.get(kv, "peridio_vsn_current", "")
      bin_current = Map.get(kv, "peridio_bin_current", "")

      kv
      |> Map.put("peridio_via_previous", src_current)
      |> Map.put("peridio_bun_previous", bun_current)
      |> Map.put("peridio_vsn_previous", vsn_current)
      |> Map.put("peridio_bin_previous", bin_current)
      |> Map.put("peridio_via_current", src_progress)
      |> Map.put("peridio_bun_current", bun_progress)
      |> Map.put("peridio_vsn_current", vsn_progress)
      |> Map.put("peridio_bin_current", bin_progress)
      |> Map.put("peridio_via_progress", "")
      |> Map.put("peridio_bun_progress", "")
      |> Map.put("peridio_vsn_progress", "")
      |> Map.put("peridio_bin_progress", "")
    end)
  end

  def reboot(cmd, opts) do
    System.cmd(cmd, opts, stderr_to_stdout: true)
  end

  def via(nil), do: nil

  def via(prn) do
    cond do
      String.contains?(prn, "release") -> Release
      String.contains?(prn, "bundle_override") -> BundleOverride
      String.contains?(prn, "bundle") -> Bundle
      true -> nil
    end
  end

  def sdk_client(sdk_client, via_prn, bundle_prn, version) do
    sdk_client =
      sdk_client
      |> Map.put(:bundle_prn, sdk_client_sanitize(bundle_prn))
      |> Map.put(:release_version, sdk_client_sanitize(version))

    case via(via_prn) do
      Release -> Map.put(sdk_client, :release_prn, via_prn)
      _ -> Map.put(sdk_client, :release_prn, nil)
    end
  end

  defp sdk_client_sanitize(""), do: nil
  defp sdk_client_sanitize(val), do: val
end

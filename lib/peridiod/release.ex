defmodule Peridiod.Release do
  alias Peridiod.{Cache, Release, Bundle}
  alias PeridiodPersistence.KV

  import Peridiod.Utils, only: [stamp_utc_now: 0]

  require Logger

  @cache_path "release"
  @stamp_cached ".stamp_cached"
  @stamp_installed ".stamp_installed"

  defstruct prn: nil,
            name: nil,
            version: nil,
            version_requirement: nil,
            bundle: nil

  @type t() :: %__MODULE__{
          prn: String.t(),
          name: String.t(),
          version: Version.t(),
          version_requirement: Version.Requirement.t(),
          bundle: Bundle.t()
        }

  defimpl Jason.Encoder, for: Release do
    def encode(%Release{} = release_metadata, opts) do
      version =
        case release_metadata.version do
          nil -> nil
          version -> Version.to_string(version)
        end

      version_requirement =
        case release_metadata.version_requirement do
          nil -> nil
          version_requirement -> version_requirement.source
        end

      release_metadata
      |> Map.take([:prn, :name, :version_requirement])
      |> Map.put(:version, version)
      |> Map.put(:version_requirement, version_requirement)
      |> Map.put(:bundle_prn, release_metadata.bundle.prn)
      |> Jason.Encode.map(opts)
    end
  end

  def metadata_from_cache(cache_pid, release_prn) do
    manifest_file = Path.join(["release", release_prn, "manifest"])

    with {:ok, json} <- Cache.read(cache_pid, manifest_file),
         {:ok, map} <- Jason.decode(json) do
      bundle_metadata = bundle_metadata_from_cache(cache_pid, map["bundle_prn"])
      map = Map.put(map, "bundle", bundle_metadata)
      {:ok, metadata_from_map(map)}
    end
  end

  def metadata_from_map(release_metadata) do
    version =
      case release_metadata["version"] do
        nil -> nil
        version -> Version.parse!(version)
      end

    version_requirement =
      case release_metadata["version_requirement"] do
        nil -> nil
        version_requirement -> Version.parse_requirement!(version_requirement)
      end

    %__MODULE__{
      prn: release_metadata["prn"],
      name: release_metadata["name"],
      version: version,
      version_requirement: version_requirement,
      bundle: release_metadata["bundle"]
    }
  end

  @doc """
  Recursively parse a release manifest into structs
  """
  @spec metadata_from_manifest(map()) :: {:ok, t()}
  def metadata_from_manifest(
        %{
          "release" => release_metadata
        } = manifest
      ) do
    version =
      case release_metadata["version"] do
        nil -> nil
        version -> Version.parse!(version)
      end

    version_requirement =
      case release_metadata["version_requirement"] do
        nil -> nil
        version_requirement -> Version.parse_requirement!(version_requirement)
      end

    bundle =
      case Bundle.metadata_from_manifest(manifest) do
        {:ok, bundle} ->
          bundle

        error ->
          Logger.error("Error loading bundle from manifest: #{inspect(error)}")
          nil
      end

    {:ok,
     %__MODULE__{
       prn: release_metadata["prn"],
       name: release_metadata["name"],
       version: version,
       version_requirement: version_requirement,
       bundle: bundle
     }}
  end

  def metadata_to_cache(
        cache_pid \\ Cache,
        %__MODULE__{prn: release_prn, bundle: bundle} = release_metadata
      ) do
    release_json = Jason.encode!(release_metadata)

    manifest_file = Path.join(["release", release_prn, "manifest"])

    with :ok <- Cache.write(cache_pid, manifest_file, release_json),
         :ok <- Bundle.metadata_to_cache(cache_pid, bundle) do
      :ok
    end
  end

  def cached?(cache_pid \\ Cache, %__MODULE__{} = release_metadata) do
    stamp_file = Path.join([cache_path(release_metadata), @stamp_cached])
    Cache.exists?(cache_pid, stamp_file)
  end

  def cache_path(%__MODULE__{prn: release_prn}) do
    Path.join([@cache_path, release_prn])
  end

  def installed?(cache_pid \\ Cache, %__MODULE__{} = release_metadata) do
    stamp_file = Path.join([cache_path(release_metadata), @stamp_installed])
    Cache.exists?(cache_pid, stamp_file)
  end

  def stamp_cached(cache_pid \\ Cache, %__MODULE__{} = release_metadata) do
    stamp_file = Path.join([cache_path(release_metadata), @stamp_cached])
    Cache.write(cache_pid, stamp_file, stamp_utc_now())
  end

  def stamp_installed(cache_pid \\ Cache, %__MODULE__{} = release_metadata) do
    stamp_file = Path.join([cache_path(release_metadata), @stamp_installed])
    Cache.write(cache_pid, stamp_file, stamp_utc_now())
  end

  def kv_progress(kv_pid \\ KV, %__MODULE__{prn: prn} = release_metadata) when not is_nil(prn) do
    version =
      case release_metadata.version do
        nil -> ""
        version -> Version.to_string(version)
      end

    KV.put_map(kv_pid, %{
      "peridio_rel_progress" => release_metadata.prn,
      "peridio_vsn_progress" => version
    })
  end

  def kv_advance(kv_pid \\ KV) do
    KV.reinitialize(kv_pid)

    KV.get_all_and_update(kv_pid, fn kv ->
      rel_progress = Map.get(kv, "peridio_rel_progress", "")
      bun_progress = Map.get(kv, "peridio_bun_progress", "")
      ovr_progress = Map.get(kv, "peridio_ovr_progress", "")
      vsn_progress = Map.get(kv, "peridio_vsn_progress", "")
      bin_progress = Map.get(kv, "peridio_bin_progress", "")

      rel_current = Map.get(kv, "peridio_rel_current", "")
      bun_current = Map.get(kv, "peridio_bun_current", "")
      ovr_current = Map.get(kv, "peridio_ovr_current", "")
      vsn_current = Map.get(kv, "peridio_vsn_current", "")
      bin_current = Map.get(kv, "peridio_bin_current", "")

      kv
      |> Map.put("peridio_rel_previous", rel_current)
      |> Map.put("peridio_rel_previous", bun_current)
      |> Map.put("peridio_ovr_previous", ovr_current)
      |> Map.put("peridio_vsn_previous", vsn_current)
      |> Map.put("peridio_bin_previous", bin_current)
      |> Map.put("peridio_rel_current", rel_progress)
      |> Map.put("peridio_bun_current", bun_progress)
      |> Map.put("peridio_ovr_current", ovr_progress)
      |> Map.put("peridio_vsn_current", vsn_progress)
      |> Map.put("peridio_bin_current", bin_progress)
      |> Map.put("peridio_rel_progress", "")
      |> Map.put("peridio_bun_progress", "")
      |> Map.put("peridio_ovr_progress", "")
      |> Map.put("peridio_vsn_progress", "")
      |> Map.put("peridio_bin_progress", "")
    end)
  end

  defp bundle_metadata_from_cache(_cache_pid, nil), do: nil

  defp bundle_metadata_from_cache(cache_pid, bundle_prn) do
    case Bundle.metadata_from_cache(cache_pid, bundle_prn) do
      {:ok, bundle_metadata} -> bundle_metadata
      _ -> nil
    end
  end
end

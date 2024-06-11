defmodule Peridiod.Release do
  alias Peridiod.{KV, Binary, Cache, Release}

  import Peridiod.Utils, only: [stamp_utc_now: 0]

  @cache_dir "release"
  @stamp_cached ".stamp_cached"
  @stamp_installed ".stamp_installed"

  defstruct prn: nil,
            name: nil,
            version: nil,
            version_requirement: nil,
            bundle_prn: nil,
            binaries: nil

  @type t() :: %__MODULE__{
          prn: String.t(),
          name: String.t(),
          version: Version.t(),
          version_requirement: Version.Requirement.t(),
          bundle_prn: String.t(),
          binaries: [Binary.t()]
        }

  defimpl Jason.Encoder, for: Release do
    def encode(%Release{} = release_metadata, opts) do
      release_metadata
      |> Map.take([:prn, :name, :version_requirement, :bundle_prn])
      |> Map.put(:version, Version.to_string(release_metadata.version))
      |> Map.put(:version_requirement, release_metadata.version_requirement.source)
      |> Jason.Encode.map(opts)
    end
  end

  def metadata_from_cache(cache_pid \\ Cache, release_prn)

  def metadata_from_cache(cache_pid, release_prn) do
    manifest_file = Path.join(["release", release_prn, "manifest"])

    with {:ok, json} <- Cache.read(cache_pid, manifest_file),
         {:ok, release_metadata} <- metadata_from_json(json) do
      binaries =
        case Cache.ls(cache_pid, Path.join(["bundle", release_metadata.bundle_prn])) do
          {:ok, binary_prns} ->
            binary_prns
            |> Enum.reduce([], fn binary_prn, acc ->
              case Binary.metadata_from_cache(cache_pid, binary_prn) do
                {:ok, binary_metadata} -> [binary_metadata | acc]
                _error -> acc
              end
            end)

          _error ->
            []
        end

      {:ok, Map.put(release_metadata, :binaries, binaries)}
    end
  end

  def metadata_from_json(json) when is_binary(json) do
    with {:ok, map} <- Jason.decode(json) do
      {:ok, metadata_from_map(map)}
    else
      error -> error
    end
  end

  def metadata_from_map(release_metadata) do
    version_requirement =
      case Version.parse_requirement(release_metadata["version_requirement"]) do
        {:ok, version_requirement} -> version_requirement
        _ -> ""
      end

    %__MODULE__{
      prn: release_metadata["prn"],
      name: release_metadata["name"],
      version: Version.parse!(release_metadata["version"]),
      version_requirement: version_requirement,
      bundle_prn: release_metadata["bundle_prn"]
    }
  end

  @doc """
  Recursively parse a release manifest into structs
  """
  @spec metadata_from_manifest(map()) :: {:ok, t()}
  def metadata_from_manifest(%{
        "release" => release_metadata,
        "manifest" => binaries,
        "bundle" => bundle
      }) do
    {:ok,
     %__MODULE__{
       prn: release_metadata["prn"],
       name: release_metadata["name"],
       version: Version.parse!(release_metadata["version"]),
       version_requirement: Version.parse_requirement!(release_metadata["version_requirement"]),
       bundle_prn: bundle["prn"],
       binaries: Enum.map(binaries, &Binary.metadata_from_manifest/1)
     }}
  end

  def metadata_to_cache(
        cache_pid \\ Cache,
        %__MODULE__{prn: release_prn, binaries: binaries} = release_metadata
      ) do
    release_json = Jason.encode!(release_metadata)

    manifest_file = Path.join(["release", release_prn, "manifest"])

    case Cache.write(cache_pid, manifest_file, release_json) do
      :ok ->
        bundle_path = Path.join(["bundle", release_metadata.bundle_prn])

        Enum.each(binaries, fn binary_metadata ->
          Binary.metadata_to_cache(cache_pid, binary_metadata)
          target = Binary.cache_dir(binary_metadata)
          link = Path.join([bundle_path, binary_metadata.prn])
          Cache.ln_s(cache_pid, target, link)
        end)

        :ok

      error ->
        error
    end
  end

  def cached?(cache_pid \\ Cache, %__MODULE__{} = release_metadata) do
    stamp_file = Path.join([cache_dir(release_metadata), @stamp_cached])
    Cache.exists?(cache_pid, stamp_file)
  end

  def cache_dir(%__MODULE__{prn: release_prn}) do
    Path.join([@cache_dir, release_prn])
  end

  def installed?(cache_pid \\ Cache, %__MODULE__{} = release_metadata) do
    stamp_file = Path.join([cache_dir(release_metadata), @stamp_installed])
    Cache.exists?(cache_pid, stamp_file)
  end

  def stamp_cached(cache_pid \\ Cache, %__MODULE__{} = release_metadata) do
    stamp_file = Path.join([cache_dir(release_metadata), @stamp_cached])
    Cache.write(cache_pid, stamp_file, stamp_utc_now())
  end

  def stamp_installed(cache_pid \\ Cache, %__MODULE__{} = release_metadata) do
    stamp_file = Path.join([cache_dir(release_metadata), @stamp_installed])
    Cache.write(cache_pid, stamp_file, stamp_utc_now())
  end

  def filter_binaries_by_targets(%__MODULE__{binaries: binaries}, []), do: binaries

  def filter_binaries_by_targets(%__MODULE__{binaries: binaries}, targets) do
    Enum.filter(binaries, &(&1.target in targets))
  end

  def kv_progress(kv_pid \\ KV, %__MODULE__{} = release_metadata) do
    KV.put_map(kv_pid, %{
      "peridio_rel_progress" => release_metadata.prn,
      "peridio_vsn_progress" => Version.to_string(release_metadata.version)
    })
  end

  def kv_advance(kv_pid \\ KV) do
    KV.get_all_and_update(kv_pid, fn kv ->
      rel_progress = Map.get(kv, "peridio_rel_progress")
      vsn_progress = Map.get(kv, "peridio_vsn_progress")
      rel_current = Map.get(kv, "peridio_rel_current")
      vsn_current = Map.get(kv, "peridio_vsn_current")

      kv
      |> Map.put("peridio_rel_previous", rel_current)
      |> Map.put("peridio_vsn_previous", vsn_current)
      |> Map.put("peridio_rel_current", rel_progress)
      |> Map.put("peridio_vsn_current", vsn_progress)
      |> Map.put("peridio_rel_progress", "")
      |> Map.put("peridio_vsn_progress", "")
    end)
  end
end

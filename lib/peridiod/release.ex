defmodule Peridiod.Release do
  use Peridiod.Cache.Helpers, cache_path: "release"

  alias Peridiod.{Cache, Release, Bundle}

  import Peridiod.Utils, only: [stamp_utc_now: 0]

  require Logger

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
      bundle_metadata =
        case Bundle.metadata_from_cache(cache_pid, map["bundle_prn"]) do
          {:ok, bundle_metadata} -> bundle_metadata
          _ -> nil
        end

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
          Logger.error("[Release] Error loading bundle from manifest: #{inspect(error)}")
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

    manifest_file = Path.join([@cache_path, release_prn, "manifest"])

    with :ok <- Cache.write(cache_pid, manifest_file, release_json),
         :ok <- Bundle.metadata_to_cache(cache_pid, bundle) do
      :ok
    end
  end
end

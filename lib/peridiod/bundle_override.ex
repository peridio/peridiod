defmodule Peridiod.BundleOverride do
  use Peridiod.Cache.Helpers, cache_path: "override"

  alias Peridiod.{BundleOverride, Bundle}

  require Logger

  defstruct prn: nil,
            bundle: nil

  @type t() :: %__MODULE__{
          prn: String.t(),
          bundle: Bundle.t()
        }

  defimpl Jason.Encoder, for: BundleOverride do
    def encode(%BundleOverride{} = override_metadata, opts) do
      override_metadata
      |> Map.take([:prn, :name, :version_requirement])
      |> Map.put(:bundle_prn, override_metadata.bundle.prn)
      |> Jason.Encode.map(opts)
    end
  end

  def metadata_from_cache(cache_pid, override_prn) do
    manifest_file = Path.join([@cache_path, override_prn, "manifest"])

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

  def metadata_from_map(override_metadata) do
    %__MODULE__{
      prn: override_metadata["prn"],
      bundle: override_metadata["bundle"]
    }
  end

  @doc """
  Recursively parse a release manifest into structs
  """
  @spec metadata_from_manifest(map()) :: {:ok, t()}
  def metadata_from_manifest(
        %{
          "bundle_override" => override_metadata
        } = manifest
      ) do
    bundle =
      case Bundle.metadata_from_manifest(manifest) do
        {:ok, bundle} ->
          bundle

        error ->
          Logger.error("[Bundle Override] Error loading bundle from manifest: #{inspect(error)}")
          nil
      end

    {:ok,
     %__MODULE__{
       prn: override_metadata["prn"],
       bundle: bundle
     }}
  end

  def metadata_to_cache(
        cache_pid \\ Cache,
        %__MODULE__{prn: override_prn, bundle: bundle} = override_metadata
      ) do
    override_json = Jason.encode!(override_metadata)
    manifest_file = Path.join([@cache_path, override_prn, "manifest"])

    with :ok <- Cache.write(cache_pid, manifest_file, override_json),
         :ok <- Bundle.metadata_to_cache(cache_pid, bundle) do
      :ok
    end
  end
end

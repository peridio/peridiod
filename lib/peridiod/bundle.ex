defmodule Peridiod.Bundle do
  use Peridiod.Cache.Helpers, cache_path: "bundle"

  alias Peridiod.{Binary, Cache, Bundle}
  alias PeridiodPersistence.KV

  defstruct prn: nil,
            binaries: nil

  @type t() :: %__MODULE__{
          prn: String.t(),
          binaries: [Binary.t()]
        }

  defimpl Jason.Encoder, for: Bundle do
    def encode(%Bundle{} = bundle_metadata, opts) do
      bundle_metadata
      |> Map.take([:prn])
      |> Jason.Encode.map(opts)
    end
  end

  def metadata_from_cache(cache_pid, bundle_prn) do
    manifest_file = Path.join([cache_path(bundle_prn), "manifest"])

    with {:ok, json} <- Cache.read(cache_pid, manifest_file),
         {:ok, bundle_metadata} <- metadata_from_json(json) do
      binaries_dir = Path.join(cache_path(bundle_metadata), "binaries")

      binaries =
        case Cache.ls(cache_pid, binaries_dir) do
          {:ok, binary_prns} ->
            binary_prns
            |> Enum.reduce([], fn dirname, acc ->
              case Binary.metadata_from_cache(cache_pid, dirname) do
                {:ok, binary_metadata} -> [binary_metadata | acc]
                _error -> acc
              end
            end)

          _error ->
            []
        end

      {:ok, Map.put(bundle_metadata, :binaries, binaries)}
    end
  end

  def metadata_from_json(json) when is_binary(json) do
    with {:ok, map} <- Jason.decode(json) do
      {:ok, metadata_from_map(map)}
    else
      error -> error
    end
  end

  def metadata_from_map(bundle_metadata) do
    %__MODULE__{
      prn: bundle_metadata["prn"]
    }
  end

  @doc """
  Recursively parse a release manifest into structs
  """
  @spec metadata_from_manifest(map()) :: {:ok, t()}
  def metadata_from_manifest(%{
        "manifest" => binaries,
        "bundle" => bundle_metadata
      }) do
    {:ok,
     %__MODULE__{
       prn: bundle_metadata["prn"],
       binaries: Enum.map(binaries, &Binary.metadata_from_manifest/1)
     }}
  end

  def metadata_to_cache(
        cache_pid \\ Cache,
        %__MODULE__{binaries: binaries} = bundle_metadata
      ) do
    bundle_json = Jason.encode!(bundle_metadata)
    bundle_path = Path.join(["bundle", bundle_metadata.prn])
    manifest_file = Path.join([bundle_path, "manifest"])

    with :ok <- Cache.write(cache_pid, manifest_file, bundle_json) do
      Enum.each(binaries, fn binary_metadata ->
        Binary.metadata_to_cache(cache_pid, binary_metadata)
        target = Binary.cache_path(binary_metadata)

        link =
          Path.join([
            bundle_path,
            "binaries",
            binary_metadata.prn <>
              ":" <> Base.encode16(binary_metadata.custom_metadata_hash, case: :lower)
          ])

        Cache.ln_s(cache_pid, target, link)
      end)
    end
  end

  def filter_binaries_by_targets(%__MODULE__{binaries: binaries}, []), do: binaries

  def filter_binaries_by_targets(%__MODULE__{binaries: binaries}, targets) do
    Enum.filter(binaries, &(&1.target in [nil, "" | targets]))
  end

  def filter_uninstalled_binaries_by_target(%__MODULE__{} = bundle_metadata, targets, opts) do
    cache_pid = opts[:cache_pid] || Cache
    kv_pid = opts[:kv_pid] || KV

    with {_, [_ | _] = binaries_metadata} <-
           {:no_targets, Bundle.filter_binaries_by_targets(bundle_metadata, targets)},
         {_, [_ | _] = binaries_metadata} <-
           {:kv_installed,
            Enum.reject(binaries_metadata, &Binary.kv_installed?(kv_pid, &1, :current))},
         {_, [_ | _] = binaries_metadata} <-
           {:cache_installed, Enum.reject(binaries_metadata, &Binary.installed?(cache_pid, &1))} do
      {:ok, binaries_metadata}
    else
      {reason, _binaries_metadata} ->
        {:error, reason}
    end
  end
end

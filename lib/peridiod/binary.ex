defmodule Peridiod.Binary do
  alias Peridiod.{Binary, Cache, Signature}
  alias PeridiodPersistence.KV
  import Peridiod.Utils, only: [stamp_utc_now: 0]

  @cache_dir "binary"
  @stamp_cached ".stamp_cached"
  @stamp_installed ".stamp_installed"
  @cache_file "binary"
  @kv_bin_installed "peridio_bin_"
  @kv_bin_stores [:previous, :current, :progress]

  defstruct prn: nil,
            name: nil,
            version: nil,
            hash: nil,
            size: nil,
            uri: nil,
            custom_metadata: %{},
            custom_metadata_hash: nil,
            target: nil,
            signatures: []

  @type t() :: %__MODULE__{
          prn: String.t(),
          name: String.t(),
          version: String.t(),
          hash: binary,
          uri: URI.t(),
          custom_metadata: map,
          custom_metadata: binary,
          target: String.t(),
          signatures: [Signature.t()]
        }

  defimpl Jason.Encoder, for: Binary do
    def encode(%Binary{} = binary_metadata, opts) do
      binary_metadata
      |> Map.take([
        :prn,
        :name,
        :version,
        :size,
        :custom_metadata,
        :target,
        :signatures
      ])
      |> Map.put(:hash, Base.encode16(binary_metadata.hash, case: :lower))
      |> Jason.Encode.map(opts)
    end
  end

  def metadata_from_cache(cache_pid, binary_prn) do
    manifest_file = Path.join([@cache_dir, binary_prn, "manifest"])

    case Cache.read(cache_pid, manifest_file) do
      {:ok, json} -> metadata_from_json(json)
      error -> error
    end
  end

  def metadata_from_json(json) when is_binary(json) do
    with {:ok, map} <- Jason.decode(json) do
      {:ok, metadata_from_map(map)}
    else
      error -> error
    end
  end

  def metadata_from_map(binary_metadata) do
    signatures =
      Map.get(binary_metadata, "signatures", []) |> Enum.map(&Signature.metadata_from_map/1)

    url =
      case Map.get(binary_metadata, "url") do
        nil -> nil
        url -> URI.new!(url)
      end

    custom_metadata = Map.get(binary_metadata, "custom_metadata", %{})

    ordered_metadata =
      custom_metadata
      |> sort_keys_recursively()
      |> Jason.encode!()

    custom_metadata_hash = :crypto.hash(:sha256, ordered_metadata)

    %__MODULE__{
      prn: binary_metadata["prn"],
      name: binary_metadata["name"],
      version: binary_metadata["version"],
      hash: Base.decode16!(binary_metadata["hash"], case: :mixed),
      size: binary_metadata["size"],
      uri: url,
      custom_metadata: custom_metadata,
      custom_metadata_hash: custom_metadata_hash,
      target: binary_metadata["target"],
      signatures: signatures
    }
  end

  def metadata_from_manifest(
        %{
          "binary_prn" => binary_prn,
          "hash" => hash,
          "url" => url,
          "target" => target,
          "size" => size
        } = binary_metadata
      ) do
    signatures =
      Map.get(binary_metadata, "signatures", []) |> Enum.map(&Signature.metadata_from_manifest/1)

    custom_metadata = Map.get(binary_metadata, "custom_metadata", %{})

    ordered_metadata =
      custom_metadata
      |> sort_keys_recursively()
      |> Jason.encode!()

    custom_metadata_hash = :crypto.hash(:sha256, ordered_metadata)

    %__MODULE__{
      prn: binary_prn,
      name: binary_metadata["artifact"]["name"],
      version: binary_metadata["artifact_version"]["version"],
      hash: Base.decode16!(hash, case: :mixed),
      size: size,
      uri: URI.new!(url),
      custom_metadata: custom_metadata,
      custom_metadata_hash: custom_metadata_hash,
      target: target,
      signatures: signatures
    }
  end

  def metadata_to_cache(
        cache_pid \\ Cache,
        %__MODULE__{prn: binary_prn} = binary_metadata
      ) do
    binary_json = Jason.encode!(binary_metadata)
    manifest_file = Path.join([@cache_dir, binary_prn, "manifest"])
    Cache.write(cache_pid, manifest_file, binary_json)
  end

  def trusted_signing_keys(%__MODULE__{signatures: signatures}, trusted_signing_keys) do
    {trusted, _untrusted} = Enum.split_with(signatures, &(&1.signing_key in trusted_signing_keys))
    trusted
  end

  def cached?(cache_pid \\ Cache, %__MODULE__{} = binary_metadata) do
    stamp_file = Path.join([cache_dir(binary_metadata), @stamp_cached])
    Cache.exists?(cache_pid, stamp_file)
  end

  def cache_dir(%__MODULE__{prn: binary_prn}) do
    Path.join([@cache_dir, binary_prn])
  end

  def cache_file(%__MODULE__{} = binary_metadata) do
    Path.join(cache_dir(binary_metadata), @cache_file)
  end

  def installed?(cache_pid \\ Cache, %__MODULE__{} = binary_metadata) do
    stamp_file = Path.join([cache_dir(binary_metadata), @stamp_installed])
    Cache.exists?(cache_pid, stamp_file)
  end

  def stamp_cached(cache_pid \\ Cache, %__MODULE__{} = binary_metadata) do
    stamp_file = Path.join([cache_dir(binary_metadata), @stamp_cached])
    Cache.write(cache_pid, stamp_file, stamp_utc_now())
  end

  def stamp_installed(cache_pid \\ Cache, %__MODULE__{} = binary_metadata) do
    stamp_file = Path.join([cache_dir(binary_metadata), @stamp_installed])
    Cache.write(cache_pid, stamp_file, stamp_utc_now())
  end

  def valid_signature?(hash, signature, public_key) do
    :crypto.verify(:eddsa, :sha256, hash, signature, [public_key, :ed25519])
  end

  def id_from_prn(binary_prn) do
    case String.split(binary_prn, ":") do
      ["prn", "1", _org_id, "binary", binary_id] -> {:ok, binary_id}
      _ -> {:error, :invalid_prn}
    end
  end

  def id_from_prn!(binary_prn) do
    {:ok, binary_id} = id_from_prn(binary_prn)
    binary_id
  end

  def id_to_bin(binary_id) do
    UUID.string_to_binary!(binary_id)
  end

  def id_bin_to_uuid(<<id::binary-size(4)>>) do
    UUID.binary_to_string!(id)
  end

  def kv_installed?(kv_pid, %__MODULE__{prn: prn} = binary_metadata, store) do
    id =
      prn
      |> id_from_prn!()
      |> id_to_bin()
      |> Base.encode16(case: :lower)

    get_all_kv_installed(kv_pid, store)
    |> Enum.any?(fn {kv_id, kv_custom_metadata_hash} ->
      kv_id == id &&
        kv_custom_metadata_hash ==
          Base.encode16(binary_metadata.custom_metadata_hash, case: :lower)
    end)
  end

  def get_all_kv_installed(kv_pid \\ KV, store) when store in @kv_bin_stores do
    KV.get(kv_pid, @kv_bin_installed <> to_string(store))
    |> parse_kv_installed()
  end

  def put_kv_installed(
        kv_pid \\ KV,
        %Binary{
          prn: prn,
          custom_metadata_hash: custom_metadata_hash
        },
        store
      )
      when store in @kv_bin_stores do
    id =
      prn
      |> id_from_prn!()
      |> id_to_bin()
      |> Base.encode16(case: :lower)

    KV.get_and_update(kv_pid, @kv_bin_installed <> to_string(store), fn installed ->
      installed
      |> parse_kv_installed()
      |> Map.put(id, Base.encode16(custom_metadata_hash, case: :lower))
      |> encode_kv_installed()
    end)
  end

  def pop_kv_installed(kv_pid \\ KV, %Binary{prn: prn}, store)
      when store in @kv_bin_stores do
    id =
      prn
      |> id_from_prn!()
      |> id_to_bin()
      |> Base.encode16(case: :lower)

    KV.get_and_update(kv_pid, @kv_bin_installed <> to_string(store), fn installed ->
      installed
      |> parse_kv_installed()
      |> Map.delete(id)
      |> encode_kv_installed()
    end)
  end

  defp parse_kv_installed(installed, acc \\ %{})
  defp parse_kv_installed(nil, _acc), do: %{}

  defp parse_kv_installed(installed, acc) when is_binary(installed) do
    installed
    |> parse_kv_installed_record(acc)
  end

  defp parse_kv_installed_record(<<>>, acc), do: acc

  defp parse_kv_installed_record(
         <<id::binary-size(32), custom_metadata_hash::binary-size(64), tail::binary>>,
         acc
       ) do
    parse_kv_installed_record(tail, Map.put(acc, id, custom_metadata_hash))
  end

  defp encode_kv_installed(map) do
    map
    |> Enum.to_list()
    |> Enum.flat_map(fn {key, value} -> [key, value] end)
    |> :erlang.list_to_binary()
  end

  defp sort_keys_recursively(map) when is_map(map) do
    map
    |> Enum.map(fn {key, value} -> {key, sort_keys_recursively(value)} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.into(%{})
  end

  defp sort_keys_recursively(list) when is_list(list) do
    Enum.map(list, &sort_keys_recursively/1)
  end

  defp sort_keys_recursively(value), do: value
end

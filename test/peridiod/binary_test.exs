defmodule Peridiod.BinaryTest do
  use PeridiodTest.Case
  doctest Peridiod.Binary

  alias Peridiod.Binary

  describe "binary encode decode" do
    setup :load_release_metadata_from_manifest
    setup :start_cache

    test "metadata write cache", %{cache_pid: cache_pid, release_metadata: release_metadata} do
      binary_metadata = List.first(release_metadata.binaries)
      assert :ok = Binary.metadata_to_cache(cache_pid, binary_metadata)
    end

    test "metadata read cache", %{
      cache_pid: cache_pid,
      release_metadata: release_metadata
    } do
      binary_metadata = List.first(release_metadata.binaries)

      %Binary{
        prn: binary_prn,
        name: binary_name,
        version: binary_version,
        hash: binary_hash,
        custom_metadata: custom_metadata,
        target: target,
        signatures: signatures,
        size: size
      } = binary_metadata

      Binary.metadata_to_cache(cache_pid, binary_metadata)

      assert {:ok,
              %Binary{
                prn: ^binary_prn,
                name: ^binary_name,
                version: ^binary_version,
                hash: ^binary_hash,
                custom_metadata: ^custom_metadata,
                target: ^target,
                signatures: ^signatures,
                size: ^size
              }} = Binary.metadata_from_cache(cache_pid, binary_prn)
    end

    test "metadata read cache missing", %{
      cache_pid: cache_pid,
      release_metadata: release_metadata
    } do
      binary_metadata = List.first(release_metadata.binaries)
      assert {:error, :enoent} = Binary.metadata_from_cache(cache_pid, binary_metadata.prn)
    end

    test "metadata read cache invalid signature", %{
      cache_pid: cache_pid,
      cache_dir: cache_dir,
      release_metadata: release_metadata
    } do
      binary_metadata = List.first(release_metadata.binaries)
      Binary.metadata_to_cache(cache_pid, binary_metadata)
      signature_file = Path.join([cache_dir, "binary", binary_metadata.prn, "manifest.sig"])
      File.write(signature_file, "")

      assert {:error, :invalid_signature} =
               Binary.metadata_from_cache(cache_pid, binary_metadata.prn)
    end

    test "stamp installed", %{
      cache_pid: cache_pid,
      cache_dir: cache_dir,
      release_metadata: release_metadata
    } do
      binary_metadata = List.first(release_metadata.binaries)
      Binary.metadata_to_cache(cache_pid, binary_metadata)
      Binary.stamp_installed(cache_pid, binary_metadata)

      stamp_installed_file =
        Path.join([cache_dir, "binary", binary_metadata.prn, ".stamp_installed"])

      assert File.exists?(stamp_installed_file)
    end
  end

  describe "binary kv" do
    setup :start_kv
    setup :load_release_metadata_from_manifest
    setup :start_cache

    test "installed", %{
      cache_pid: cache_pid,
      kv_pid: kv_pid,
      release_metadata: release_metadata
    } do
      binary_metadata = List.first(release_metadata.binaries)
      Binary.metadata_to_cache(cache_pid, binary_metadata)
      assert {:ok, _contents} = Binary.put_kv_installed(kv_pid, binary_metadata, :progress)
      kv_installed = Binary.get_all_kv_installed(kv_pid, :progress)

      id =
        binary_metadata.prn
        |> Binary.id_from_prn!()
        |> Binary.id_to_bin()
        |> Base.encode16(case: :lower)

      custom_metadata_hash = binary_metadata.custom_metadata_hash |> Base.encode16(case: :lower)
      assert Map.has_key?(kv_installed, id)
      assert ^custom_metadata_hash = Map.get(kv_installed, id)
    end

    test "pop", %{
      cache_pid: cache_pid,
      kv_pid: kv_pid,
      release_metadata: release_metadata
    } do
      binary_metadata = List.first(release_metadata.binaries)
      Binary.metadata_to_cache(cache_pid, binary_metadata)
      Binary.put_kv_installed(kv_pid, binary_metadata, :progress)
      Binary.pop_kv_installed(kv_pid, binary_metadata, :progress)
      kv_installed = Binary.get_all_kv_installed(kv_pid, :progress)

      id =
        binary_metadata.prn
        |> Binary.id_from_prn!()
        |> Binary.id_to_bin()
        |> Base.encode16(case: :lower)

      refute Map.has_key?(kv_installed, id)
    end
  end
end

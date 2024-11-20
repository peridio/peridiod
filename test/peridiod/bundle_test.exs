defmodule Peridiod.BundleTest do
  use PeridiodTest.Case
  doctest Peridiod.Bundle

  alias Peridiod.{Bundle, Binary}

  test "bundle parse manifest", %{release_manifest: release_manifest} do
    assert {:ok, %Bundle{}} = Bundle.metadata_from_manifest(release_manifest)
  end

  describe "bundle encode decode" do
    setup :load_bundle_metadata_from_manifest
    setup :start_cache

    test "metadata write cache", %{cache_pid: cache_pid, bundle_metadata: bundle_metadata} do
      assert :ok = Bundle.metadata_to_cache(cache_pid, bundle_metadata)
    end

    test "metadata read cache", %{
      cache_pid: cache_pid,
      bundle_metadata:
        %Bundle{
          prn: prn
        } = bundle_metadata
    } do
      Bundle.metadata_to_cache(cache_pid, bundle_metadata)

      [
        %Binary{
          prn: binary_prn,
          name: binary_name,
          version: binary_version,
          hash: binary_hash,
          custom_metadata: custom_metadata,
          target: target,
          signatures: signatures,
          size: size
        }
      ] = bundle_metadata.binaries

      assert {:ok,
              %Bundle{
                prn: ^prn,
                binaries: [
                  %Binary{
                    prn: ^binary_prn,
                    name: ^binary_name,
                    version: ^binary_version,
                    hash: ^binary_hash,
                    custom_metadata: ^custom_metadata,
                    target: ^target,
                    signatures: ^signatures,
                    size: ^size
                  }
                ]
              }} = Bundle.metadata_from_cache(cache_pid, bundle_metadata.prn)
    end

    test "metadata read cache missing", %{
      cache_pid: cache_pid,
      cache_dir: cache_dir,
      bundle_metadata: bundle_metadata
    } do
      Bundle.metadata_to_cache(cache_pid, bundle_metadata)
      File.rm_rf(cache_dir)
      assert {:error, :enoent} = Bundle.metadata_from_cache(cache_pid, bundle_metadata.prn)
    end

    test "metadata read cache invalid signature", %{
      cache_pid: cache_pid,
      cache_dir: cache_dir,
      bundle_metadata: bundle_metadata
    } do
      Bundle.metadata_to_cache(cache_pid, bundle_metadata)
      signature_file = Path.join([cache_dir, "bundle", bundle_metadata.prn, "manifest.sig"])
      File.write(signature_file, "")

      assert {:error, :invalid_signature} =
               Bundle.metadata_from_cache(cache_pid, bundle_metadata.prn)
    end
  end
end

defmodule Peridiod.ReleaseTest do
  use PeridiodTest.Case
  doctest Peridiod.Release

  alias Peridiod.{Binary, Release}

  test "release parse manifest", %{release_manifest: release_manifest} do
    assert {:ok, %Release{}} = Release.metadata_from_manifest(release_manifest)
  end

  describe "release encode decode" do
    setup :load_release_metadata_from_manifest
    setup :start_cache

    test "metadata write cache", %{cache_pid: cache_pid, release_metadata: release_metadata} do
      assert :ok = Release.metadata_to_cache(cache_pid, release_metadata)
    end

    test "metadata read cache", %{
      cache_pid: cache_pid,
      release_metadata:
        %Release{
          prn: prn,
          bundle: _bundle,
          name: name,
          version: version,
          version_requirement: version_requirement
        } = release_metadata
    } do
      Release.metadata_to_cache(cache_pid, release_metadata)

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
      ] = release_metadata.bundle.binaries

      release_metadata = Release.metadata_from_cache(cache_pid, release_metadata.prn)

      assert {:ok,
              %Release{
                prn: ^prn,
                bundle: %{
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
                },
                name: ^name,
                version: ^version,
                version_requirement: ^version_requirement
              }} = release_metadata
    end

    test "metadata read cache missing", %{
      cache_pid: cache_pid,
      cache_dir: cache_dir,
      release_metadata: release_metadata
    } do
      Release.metadata_to_cache(cache_pid, release_metadata)
      File.rm_rf(cache_dir)
      assert {:error, :enoent} = Release.metadata_from_cache(cache_pid, release_metadata.prn)
    end

    test "metadata read cache invalid signature", %{
      cache_pid: cache_pid,
      cache_dir: cache_dir,
      release_metadata: release_metadata
    } do
      Release.metadata_to_cache(cache_pid, release_metadata)
      signature_file = Path.join([cache_dir, "release", release_metadata.prn, "manifest.sig"])
      File.write(signature_file, "")

      assert {:error, :invalid_signature} =
               Release.metadata_from_cache(cache_pid, release_metadata.prn)
    end
  end
end

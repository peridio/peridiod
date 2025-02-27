defmodule Peridiod.Bundle.ServerTest do
  use PeridiodTest.Case
  doctest Peridiod.Bundle.Server

  alias Peridiod.{Binary, Release, Bundle, Cache}
  alias PeridiodPersistence.KV

  describe "binary" do
    setup :start_cache
    setup :load_release_metadata_from_manifest
    setup :start_plan_server
    setup :start_bundle_server

    test "cache trusted signatures", %{
      bundle_server_pid: bundle_server_pid,
      release_metadata: %Release{bundle: %{binaries: binaries}}
    } do
      binary_metadata = List.first(binaries)
      signing_key = List.first(binary_metadata.signatures).signing_key
      {:ok, _signatures} = Bundle.Server.add_trusted_signing_key(bundle_server_pid, signing_key)
      assert :ok = Bundle.Server.cache_binary(bundle_server_pid, binary_metadata)
      assert_receive {Bundle.Server, ^bundle_server_pid, :complete}
    end

    test "cache untrusted signatures", %{
      bundle_server_pid: bundle_server_pid,
      release_metadata: %Release{bundle: %{binaries: binaries}}
    } do
      binary_metadata = List.first(binaries)

      assert {:error, :untrusted_signatures} =
               Bundle.Server.cache_binary(bundle_server_pid, binary_metadata)
    end

    test "install untrusted signatures", %{
      bundle_server_pid: bundle_server_pid,
      release_metadata: %Release{bundle: %{binaries: binaries}}
    } do
      binary_metadata = List.first(binaries)

      assert {:error, :untrusted_signatures} =
               Bundle.Server.install_binary(bundle_server_pid, binary_metadata)
    end

    test "already cached", %{
      cache_pid: cache_pid,
      bundle_server_pid: bundle_server_pid,
      release_metadata: %Release{bundle: %{binaries: binaries}}
    } do
      binary_metadata = List.first(binaries)
      :ok = Binary.metadata_to_cache(cache_pid, binary_metadata)
      signing_key = List.first(binary_metadata.signatures).signing_key
      {:ok, _signatures} = Bundle.Server.add_trusted_signing_key(bundle_server_pid, signing_key)
      assert :ok = Binary.stamp_cached(cache_pid, binary_metadata)

      assert {:error, :already_cached} =
               Bundle.Server.cache_binary(bundle_server_pid, binary_metadata)
    end

    test "already installed", %{
      cache_pid: cache_pid,
      bundle_server_pid: bundle_server_pid,
      release_metadata: %Release{bundle: %{binaries: binaries}}
    } do
      binary_metadata = List.first(binaries)
      :ok = Binary.metadata_to_cache(cache_pid, binary_metadata)
      signing_key = List.first(binary_metadata.signatures).signing_key
      {:ok, _signatures} = Bundle.Server.add_trusted_signing_key(bundle_server_pid, signing_key)
      assert :ok = Binary.stamp_installed(cache_pid, binary_metadata)

      assert {:error, :already_installed} =
               Bundle.Server.install_binary(bundle_server_pid, binary_metadata)
    end
  end

  describe "release" do
    setup :start_cache
    setup :start_kv
    setup :load_release_metadata_from_manifest
    setup :start_plan_server
    setup :start_bundle_server

    test "cache trusted signatures", %{
      bundle_server_pid: bundle_server_pid,
      release_metadata: %Release{bundle: %{binaries: binaries}} = release_metadata
    } do
      binary_metadata = List.first(binaries)
      signing_key = List.first(binary_metadata.signatures).signing_key
      {:ok, _signatures} = Bundle.Server.add_trusted_signing_key(bundle_server_pid, signing_key)
      assert :ok = Bundle.Server.cache_bundle(bundle_server_pid, release_metadata.bundle)

      assert_receive {Bundle.Server, ^bundle_server_pid, :complete}
    end

    test "cache untrusted signatures", %{
      bundle_server_pid: bundle_server_pid,
      release_metadata: %Release{} = release_metadata
    } do
      assert {:error, :untrusted_signatures} =
               Bundle.Server.cache_bundle(bundle_server_pid, release_metadata.bundle)
    end

    test "install untrusted signatures", %{
      bundle_server_pid: bundle_server_pid,
      release_metadata: %Release{} = release_metadata
    } do
      assert {:error, :untrusted_signatures} =
               Bundle.Server.install_bundle(bundle_server_pid, release_metadata)
    end

    test "already cached", %{
      cache_pid: cache_pid,
      bundle_server_pid: bundle_server_pid,
      release_metadata: %Release{bundle: %{binaries: binaries} = bundle_metadata}
    } do
      binary_metadata = List.first(binaries)
      signing_key = List.first(binary_metadata.signatures).signing_key
      {:ok, _signatures} = Bundle.Server.add_trusted_signing_key(bundle_server_pid, signing_key)
      assert :ok = Bundle.stamp_cached(cache_pid, bundle_metadata)

      assert {:error, :already_cached} =
               Bundle.Server.cache_bundle(bundle_server_pid, bundle_metadata)
    end
  end

  describe "binary install cache" do
    setup :start_cache
    setup :load_release_metadata_from_manifest
    setup :start_plan_server
    setup :start_bundle_server
    setup :cache_binary

    test "file from cache", %{
      cache_pid: cache_pid,
      bundle_server_pid: bundle_server_pid,
      release_metadata: %Release{bundle: %{binaries: binaries}}
    } do
      binary_metadata = List.first(binaries)
      cache_file = Binary.cache_file(binary_metadata)

      true = Binary.cached?(cache_pid, binary_metadata)
      true = Cache.exists?(cache_pid, cache_file)

      signing_key = List.first(binary_metadata.signatures).signing_key
      {:ok, _signatures} = Bundle.Server.add_trusted_signing_key(bundle_server_pid, signing_key)
      Bundle.Server.install_binary(bundle_server_pid, binary_metadata)

      refute Binary.installed?(cache_pid, binary_metadata)
      assert_receive {Bundle.Server, ^bundle_server_pid, :complete}
      assert Binary.installed?(cache_pid, binary_metadata)
    end
  end

  describe "binary install download" do
    setup :start_cache
    setup :load_release_metadata_from_manifest
    setup :start_plan_server
    setup :start_bundle_server

    test "file url to cache", %{
      cache_pid: cache_pid,
      bundle_server_pid: bundle_server_pid,
      release_metadata: %Release{bundle: %{binaries: binaries}}
    } do
      binary_metadata = List.first(binaries)
      cache_file = Binary.cache_file(binary_metadata)

      false = Binary.cached?(cache_pid, binary_metadata)
      false = Cache.exists?(cache_pid, cache_file)

      signing_key = List.first(binary_metadata.signatures).signing_key
      {:ok, _signatures} = Bundle.Server.add_trusted_signing_key(bundle_server_pid, signing_key)

      refute Binary.installed?(cache_pid, binary_metadata)
      assert :ok = Bundle.Server.install_binary(bundle_server_pid, binary_metadata)
      assert_receive {Bundle.Server, ^bundle_server_pid, :complete}
      assert Binary.installed?(cache_pid, binary_metadata)
    end
  end

  describe "bundle install cache" do
    setup :start_cache
    setup :start_kv
    setup :load_release_metadata_from_manifest
    setup :start_plan_server
    setup :start_bundle_server
    setup :cache_binary

    test "file from cache", %{
      cache_pid: cache_pid,
      bundle_server_pid: bundle_server_pid,
      release_metadata: %Release{bundle: %{binaries: binaries}} = release_metadata
    } do
      bundle_metadata = release_metadata.bundle
      binary_metadata = List.first(binaries)
      cache_file = Binary.cache_file(binary_metadata)

      true = Binary.cached?(cache_pid, binary_metadata)
      true = Cache.exists?(cache_pid, cache_file)

      signing_key = List.first(binary_metadata.signatures).signing_key
      {:ok, _signatures} = Bundle.Server.add_trusted_signing_key(bundle_server_pid, signing_key)

      refute Bundle.installed?(cache_pid, bundle_metadata)
      assert :ok = Bundle.Server.install_bundle(bundle_server_pid, bundle_metadata)
      assert_receive {Bundle.Server, ^bundle_server_pid, :complete}
      assert Bundle.installed?(cache_pid, bundle_metadata)
    end

    test "cache cleanup", %{
      cache_pid: cache_pid,
      cache_dir: cache_dir,
      kv_pid: kv_pid,
      bundle_server_pid: bundle_server_pid,
      release_metadata: %Release{bundle: %{binaries: binaries} = bundle_metadata}
    } do
      binary_metadata = List.first(binaries)
      cache_file = Binary.cache_file(binary_metadata)

      true = Binary.cached?(cache_pid, binary_metadata)
      true = Cache.exists?(cache_pid, cache_file)

      test_bundle_path = Path.join([cache_dir, "bundle", "1234"])
      :ok = File.mkdir_p(test_bundle_path)

      signing_key = List.first(binary_metadata.signatures).signing_key
      {:ok, _signatures} = Bundle.Server.add_trusted_signing_key(bundle_server_pid, signing_key)
      prn = bundle_metadata.prn

      refute Bundle.installed?(cache_pid, bundle_metadata)
      assert :ok = Bundle.Server.install_bundle(bundle_server_pid, bundle_metadata)
      assert_receive {Bundle.Server, ^bundle_server_pid, :complete}
      assert KV.get(kv_pid, "peridio_bun_current") == prn
      assert KV.get(kv_pid, "peridio_bun_progress") == ""
      refute File.exists?(test_bundle_path)
    end
  end

  describe "bundle install" do
    setup :start_cache
    setup :start_kv
    setup :load_release_metadata_from_manifest
    setup :start_plan_server
    setup :start_bundle_server

    test "from downloader", %{
      cache_pid: cache_pid,
      bundle_server_pid: bundle_server_pid,
      release_metadata: %Release{bundle: %{binaries: binaries}} = release_metadata
    } do
      binary_metadata = List.first(binaries)
      cache_file = Binary.cache_file(binary_metadata)

      false = Binary.cached?(cache_pid, binary_metadata)
      false = Cache.exists?(cache_pid, cache_file)

      signing_key = List.first(binary_metadata.signatures).signing_key
      {:ok, _signatures} = Bundle.Server.add_trusted_signing_key(bundle_server_pid, signing_key)

      Bundle.Server.install_bundle(bundle_server_pid, release_metadata)
      assert_receive {Bundle.Server, ^bundle_server_pid, :complete}
    end

    test "reboot", %{
      cache_pid: cache_pid,
      bundle_server_pid: bundle_server_pid,
      release_metadata: %Release{bundle: %{binaries: binaries}} = release_metadata
    } do
      binary_metadata = List.first(binaries)
      cache_file = Binary.cache_file(binary_metadata)

      custom_metadata =
        binary_metadata.custom_metadata
        |> update_in(["peridiod", "reboot_required"], fn _ -> true end)

      binary_metadata = %{binary_metadata | custom_metadata: custom_metadata}
      bundle_metadata = %{release_metadata.bundle | binaries: [binary_metadata]}
      release_metadata = %{release_metadata | bundle: bundle_metadata}

      false = Binary.cached?(cache_pid, binary_metadata)
      false = Cache.exists?(cache_pid, cache_file)

      signing_key = List.first(binary_metadata.signatures).signing_key
      {:ok, _signatures} = Bundle.Server.add_trusted_signing_key(bundle_server_pid, signing_key)

      Bundle.Server.install_bundle(bundle_server_pid, release_metadata)
      assert_receive {Bundle.Server, ^bundle_server_pid, :complete}
      # assert_receive {Bundle.Server, ^bundle_server_pid, :reboot}
    end
  end

  def cache_binary(
        %{
          cache_pid: cache_pid,
          release_metadata: %Release{bundle: %{binaries: binaries}}
        } = context
      ) do
    binary_metadata = List.first(binaries)
    test_file = Peridiod.TestFixtures.binary_fixture_path() |> Path.join("1M.bin")
    content = File.read!(test_file)
    cache_file = Binary.cache_file(binary_metadata)
    :ok = Cache.write(cache_pid, cache_file, content)
    :ok = Binary.stamp_cached(cache_pid, binary_metadata)
    context
  end
end

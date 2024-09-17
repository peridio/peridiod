defmodule Peridiod.Release.ServerTest do
  use PeridiodTest.Case
  doctest Peridiod.Release.Server

  alias Peridiod.{Binary, Release, Cache}

  describe "binary" do
    setup :start_cache
    setup :load_release_metadata_from_manifest
    setup :start_release_server

    test "cache trusted signatures", %{
      release_server_pid: release_server_pid,
      release_metadata: %Release{binaries: binaries}
    } do
      binary_metadata = List.first(binaries)
      signing_key = List.first(binary_metadata.signatures).signing_key
      {:ok, _signatures} = Release.Server.add_trusted_signing_key(release_server_pid, signing_key)
      assert :ok = Release.Server.cache_binary(release_server_pid, binary_metadata)
      prn = binary_metadata.prn
      assert_receive {Release.Server, :download, ^prn, :complete}
    end

    test "cache untrusted signatures", %{
      release_server_pid: release_server_pid,
      release_metadata: %Release{binaries: binaries}
    } do
      binary_metadata = List.first(binaries)

      assert {:error, :untrusted_signatures} =
               Release.Server.cache_binary(release_server_pid, binary_metadata)
    end

    test "install untrusted signatures", %{
      release_server_pid: release_server_pid,
      release_metadata: %Release{binaries: binaries}
    } do
      binary_metadata = List.first(binaries)

      assert {:error, :untrusted_signatures} =
               Release.Server.install_binary(release_server_pid, binary_metadata)
    end

    test "already cached", %{
      cache_pid: cache_pid,
      release_server_pid: release_server_pid,
      release_metadata: %Release{binaries: binaries}
    } do
      binary_metadata = List.first(binaries)
      :ok = Binary.metadata_to_cache(cache_pid, binary_metadata)
      signing_key = List.first(binary_metadata.signatures).signing_key
      {:ok, _signatures} = Release.Server.add_trusted_signing_key(release_server_pid, signing_key)
      assert :ok = Binary.stamp_cached(cache_pid, binary_metadata)

      assert {:error, :already_cached} =
               Release.Server.cache_binary(release_server_pid, binary_metadata)
    end

    test "already installed", %{
      cache_pid: cache_pid,
      release_server_pid: release_server_pid,
      release_metadata: %Release{binaries: binaries}
    } do
      binary_metadata = List.first(binaries)
      :ok = Binary.metadata_to_cache(cache_pid, binary_metadata)
      signing_key = List.first(binary_metadata.signatures).signing_key
      {:ok, _signatures} = Release.Server.add_trusted_signing_key(release_server_pid, signing_key)
      assert :ok = Binary.stamp_installed(cache_pid, binary_metadata)

      assert {:error, :already_installed} =
               Release.Server.install_binary(release_server_pid, binary_metadata)
    end
  end

  describe "release" do
    setup :start_cache
    setup :start_kv
    setup :load_release_metadata_from_manifest
    setup :start_release_server

    test "cache trusted signatures", %{
      release_server_pid: release_server_pid,
      release_metadata: %Release{binaries: binaries} = release_metadata
    } do
      binary_metadata = List.first(binaries)
      signing_key = List.first(binary_metadata.signatures).signing_key
      {:ok, _signatures} = Release.Server.add_trusted_signing_key(release_server_pid, signing_key)
      assert :ok = Release.Server.cache_release(release_server_pid, release_metadata)
      prn = binary_metadata.prn
      assert_receive {Release.Server, :download, ^prn, :complete}
    end

    test "cache untrusted signatures", %{
      release_server_pid: release_server_pid,
      release_metadata: %Release{} = release_metadata
    } do
      assert {:error, :untrusted_signatures} =
               Release.Server.cache_release(release_server_pid, release_metadata)
    end

    test "install untrusted signatures", %{
      release_server_pid: release_server_pid,
      release_metadata: %Release{} = release_metadata
    } do
      assert {:error, :untrusted_signatures} =
               Release.Server.install_release(release_server_pid, release_metadata)
    end

    test "already cached", %{
      cache_pid: cache_pid,
      release_server_pid: release_server_pid,
      release_metadata: %Release{binaries: binaries} = release_metadata
    } do
      binary_metadata = List.first(binaries)
      signing_key = List.first(binary_metadata.signatures).signing_key
      {:ok, _signatures} = Release.Server.add_trusted_signing_key(release_server_pid, signing_key)
      assert :ok = Release.stamp_cached(cache_pid, release_metadata)

      assert {:error, :already_cached} =
               Release.Server.cache_release(release_server_pid, release_metadata)
    end
  end

  describe "binary install cache" do
    setup :start_cache
    setup :load_release_metadata_from_manifest
    setup :start_release_server
    setup :cache_binary

    test "file from cache", %{
      cache_pid: cache_pid,
      release_server_pid: release_server_pid,
      release_metadata: %Release{binaries: binaries}
    } do
      binary_metadata = List.first(binaries)
      cache_file = Binary.cache_file(binary_metadata)

      true = Binary.cached?(cache_pid, binary_metadata)
      true = Cache.exists?(cache_pid, cache_file)

      signing_key = List.first(binary_metadata.signatures).signing_key
      {:ok, _signatures} = Release.Server.add_trusted_signing_key(release_server_pid, signing_key)
      Release.Server.install_binary(release_server_pid, binary_metadata)
      prn = binary_metadata.prn
      refute Binary.installed?(cache_pid, binary_metadata)
      assert_receive {Release.Server, :install, ^prn, :complete}
      assert Binary.installed?(cache_pid, binary_metadata)
    end
  end

  describe "binary install download" do
    setup :start_cache
    setup :load_release_metadata_from_manifest
    setup :start_release_server

    test "file url to cache", %{
      cache_pid: cache_pid,
      release_server_pid: release_server_pid,
      release_metadata: %Release{binaries: binaries}
    } do
      binary_metadata = List.first(binaries)
      cache_file = Binary.cache_file(binary_metadata)

      false = Binary.cached?(cache_pid, binary_metadata)
      false = Cache.exists?(cache_pid, cache_file)

      signing_key = List.first(binary_metadata.signatures).signing_key
      {:ok, _signatures} = Release.Server.add_trusted_signing_key(release_server_pid, signing_key)
      prn = binary_metadata.prn
      refute Binary.installed?(cache_pid, binary_metadata)
      assert :ok = Release.Server.install_binary(release_server_pid, binary_metadata)
      assert_receive {Release.Server, :install, ^prn, :complete}
      assert Binary.installed?(cache_pid, binary_metadata)
    end
  end

  describe "release install cache" do
    setup :start_cache
    setup :start_kv
    setup :load_release_metadata_from_manifest
    setup :start_release_server
    setup :cache_binary

    test "file from cache", %{
      cache_pid: cache_pid,
      release_server_pid: release_server_pid,
      release_metadata: %Release{binaries: binaries} = release_metadata
    } do
      binary_metadata = List.first(binaries)
      cache_file = Binary.cache_file(binary_metadata)

      true = Binary.cached?(cache_pid, binary_metadata)
      true = Cache.exists?(cache_pid, cache_file)

      signing_key = List.first(binary_metadata.signatures).signing_key
      {:ok, _signatures} = Release.Server.add_trusted_signing_key(release_server_pid, signing_key)
      prn = release_metadata.prn
      refute Release.installed?(cache_pid, release_metadata)
      assert :ok = Release.Server.install_release(release_server_pid, release_metadata)
      assert_receive {Release.Server, :install, ^prn, :complete}
      assert Release.installed?(cache_pid, release_metadata)
    end
  end

  describe "release install" do
    setup :start_cache
    setup :start_kv
    setup :load_release_metadata_from_manifest
    setup :start_release_server

    test "from downloader", %{
      cache_pid: cache_pid,
      release_server_pid: release_server_pid,
      release_metadata: %Release{binaries: binaries} = release_metadata
    } do
      binary_metadata = List.first(binaries)
      cache_file = Binary.cache_file(binary_metadata)

      false = Binary.cached?(cache_pid, binary_metadata)
      false = Cache.exists?(cache_pid, cache_file)

      signing_key = List.first(binary_metadata.signatures).signing_key
      {:ok, _signatures} = Release.Server.add_trusted_signing_key(release_server_pid, signing_key)

      Release.Server.install_release(release_server_pid, release_metadata)
      prn = release_metadata.prn
      assert_receive {Release.Server, :install, ^prn, :complete}
    end

    test "reboot", %{
      cache_pid: cache_pid,
      release_server_pid: release_server_pid,
      release_metadata: %Release{binaries: binaries} = release_metadata
    } do
      binary_metadata = List.first(binaries)
      cache_file = Binary.cache_file(binary_metadata)

      custom_metadata =
        binary_metadata.custom_metadata
        |> update_in(["peridiod", "reboot_required"], fn _ -> true end)

      binary_metadata = %{binary_metadata | custom_metadata: custom_metadata}
      release_metadata = %{release_metadata | binaries: [binary_metadata]}

      false = Binary.cached?(cache_pid, binary_metadata)
      false = Cache.exists?(cache_pid, cache_file)

      signing_key = List.first(binary_metadata.signatures).signing_key
      {:ok, _signatures} = Release.Server.add_trusted_signing_key(release_server_pid, signing_key)

      Release.Server.install_release(release_server_pid, release_metadata)
      prn = release_metadata.prn
      assert_receive {Release.Server, :install, ^prn, :complete}
      assert_receive {Release.Server, :install, ^prn, :reboot}
    end
  end

  def cache_binary(
        %{
          cache_pid: cache_pid,
          release_metadata: %Release{binaries: binaries}
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

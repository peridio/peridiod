defmodule Peridiod.Plan.StepTest do
  use PeridiodTest.Case
  doctest Peridiod.Plan.Step

  alias Peridiod.{Binary, Cache}
  alias Peridiod.Binary.Installer
  alias Peridiod.Plan.Step

  describe "binary cache" do
    setup :start_cache
    setup :load_release_metadata_from_manifest

    test "complete", %{
      cache_pid: cache_pid,
      release_metadata: %{bundle: %{binaries: binaries}}
    } do
      binary_metadata = List.first(binaries)
      step_mod = Step.BinaryCache
      step_opts = %{binary_metadata: binary_metadata, cache_pid: cache_pid, callback: self()}
      {:ok, step_pid} = Step.start_link({step_mod, step_opts})
      Step.execute(step_pid)
      cache_file = Binary.cache_file(binary_metadata)
      assert_receive {Step, ^step_pid, :complete}
      assert Binary.cached?(cache_pid, binary_metadata)
      assert Cache.exists?(cache_pid, cache_file)
    end

    test "error", %{
      cache_pid: cache_pid,
      release_metadata: %{bundle: %{binaries: binaries}}
    } do
      binary_metadata = List.first(binaries)
      step_mod = Step.BinaryCache
      {:ok, uri} = URI.new("http://localhost:4001/1M-error.bin")

      step_opts = %{
        binary_metadata: binary_metadata,
        uri: uri,
        cache_pid: cache_pid,
        callback: self()
      }

      {:ok, step_pid} = Step.start_link({step_mod, step_opts})
      Step.execute(step_pid)

      assert_receive {Step, ^step_pid, {:error, :invalid_signature}}
    end
  end

  describe "binary install" do
    setup :start_cache
    setup :start_kv
    setup :load_release_metadata_from_manifest

    test "complete uri", %{
      cache_pid: cache_pid,
      kv_pid: kv_pid,
      cache_dir: cache_dir,
      release_metadata: %{bundle: %{binaries: binaries}}
    } do
      binary_metadata = List.first(binaries)
      step_mod = Step.BinaryInstall

      step_opts = %{
        binary_metadata: binary_metadata,
        cache_pid: cache_pid,
        kv_pid: kv_pid,
        callback: self(),
        installer_mod: Installer.File,
        installer_opts: %{"name" => "test", "path" => cache_dir},
        source: binary_metadata.uri
      }

      {:ok, step_pid} = Step.start_link({step_mod, step_opts})
      Step.execute(step_pid)

      assert_receive {Step, ^step_pid, :complete}
      assert Binary.installed?(cache_pid, binary_metadata)
    end

    test "error uri", %{
      cache_pid: cache_pid,
      kv_pid: kv_pid,
      cache_dir: cache_dir,
      release_metadata: %{bundle: %{binaries: binaries}}
    } do
      binary_metadata = List.first(binaries)
      step_mod = Step.BinaryInstall

      {:ok, uri} = URI.new("http://localhost:4001/1M-error.bin")

      step_opts = %{
        binary_metadata: binary_metadata,
        cache_pid: cache_pid,
        kv_pid: kv_pid,
        callback: self(),
        installer_mod: Installer.File,
        installer_opts: %{"name" => "test", "path" => cache_dir},
        source: uri
      }

      {:ok, step_pid} = Step.start_link({step_mod, step_opts})
      Step.execute(step_pid)

      assert_receive {Step, ^step_pid, {:error, :invalid_hash}}
      refute Binary.installed?(cache_pid, binary_metadata)
    end

    test "complete cache", %{
      cache_pid: cache_pid,
      kv_pid: kv_pid,
      cache_dir: cache_dir,
      release_metadata: %{bundle: %{binaries: binaries}}
    } do
      binary_metadata = List.first(binaries)
      test_file = Peridiod.TestFixtures.binary_fixture_path() |> Path.join("1M.bin")
      content = File.read!(test_file)
      cache_file = Binary.cache_file(binary_metadata)
      :ok = Cache.write(cache_pid, cache_file, content)
      :ok = Binary.stamp_cached(cache_pid, binary_metadata)

      step_mod = Step.BinaryInstall

      step_opts = %{
        binary_metadata: binary_metadata,
        cache_pid: cache_pid,
        kv_pid: kv_pid,
        callback: self(),
        installer_mod: Installer.File,
        installer_opts: %{"name" => "test", "path" => cache_dir},
        source: :cache
      }

      {:ok, step_pid} = Step.start_link({step_mod, step_opts})
      Step.execute(step_pid)

      assert_receive {Step, ^step_pid, :complete}
      assert Binary.installed?(cache_pid, binary_metadata)
    end
  end

  describe "system reboot" do
    test "complete" do
      step_mod = Step.SystemReboot

      step_opts = %{
        reboot_cmd: "",
        reboot_opts: [],
        reboot_delay: 0,
        reboot_sync_cmd: "",
        reboot_sync_opts: [],
        callback: self()
      }

      {:ok, step_pid} = Step.start_link({step_mod, step_opts})
      Step.execute(step_pid)

      assert_receive :reboot
      assert_receive {Step, ^step_pid, :complete}
    end
  end
end

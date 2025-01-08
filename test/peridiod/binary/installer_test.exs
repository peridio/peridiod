defmodule Peridiod.Binary.InstallerTest do
  use PeridiodTest.Case
  doctest Peridiod.Binary.Installer

  alias Peridiod.Binary
  alias Peridiod.Binary.Installer
  alias Peridiod.TestFixtures

  describe "fwup" do
    setup :start_cache
    setup :start_kv
    setup :setup_fwup

    test "install task upgrade", %{binary_metadata: binary_metadata, opts: opts} = context do
      spawn_installer(binary_metadata, opts)
      prn = binary_metadata.prn
      assert_receive {Installer, ^prn, :complete}
      assert File.exists?(context.upgrade_file)
    end

    @tag capture_log: true
    test "install task error", %{binary_metadata: binary_metadata, opts: opts} do
      binary_metadata = update_installer_opts(binary_metadata, "task", "does_not_exist")
      spawn_installer(binary_metadata, opts)
      assert_receive {Installer, _, {:error, error}}
      assert error =~ "does_not_exist"
    end

    @tag capture_log: true
    test "invalid signature", %{binary_metadata: binary_metadata, opts: opts} do
      untrusted = TestFixtures.untrusted_release_binary() |> Binary.metadata_from_manifest()
      binary_metadata = Map.put(binary_metadata, :signatures, untrusted.signatures)
      spawn_installer(binary_metadata, opts)
      assert_receive {Installer, _, {:error, :invalid_signature}}
    end
  end

  describe "install_downloader" do
    setup :start_cache
    setup :start_kv
    setup :setup_cache

    test "cache", %{binary_metadata: binary_metadata, opts: opts} do
      spawn_installer(binary_metadata, opts)
      prn = binary_metadata.prn
      assert_receive {Installer, ^prn, :complete}
    end
  end

  def setup_cache(context) do
    application_config = Application.get_all_env(:peridiod)
    config = struct(Peridiod.Config, application_config) |> Peridiod.Config.new()
    binary_metadata = TestFixtures.binary_manifest_cache() |> Binary.metadata_from_manifest()
    opts = %{callback: self(), config: config, cache_pid: context.cache_pid}

    context
    |> Map.put(:binary_metadata, binary_metadata)
    |> Map.put(:opts, opts)
  end

  def setup_fwup(context) do
    application_config = Application.get_all_env(:peridiod)
    config = struct(Peridiod.Config, application_config) |> Peridiod.Config.new()
    binary_metadata = TestFixtures.binary_manifest_fwup() |> Binary.metadata_from_manifest()
    working_dir = "test/workspace/install/#{context.test}"
    File.mkdir_p(working_dir)
    devpath = Path.join(working_dir, "fwup.img")
    upgrade_file = Path.join(working_dir, "upgrade")

    binary_metadata =
      binary_metadata
      |> update_installer_opts("devpath", devpath)
      |> update_installer_opts("env", %{"PERIDIO_EXECUTE" => "touch \"#{upgrade_file}\""})

    :os.cmd(~c"fwup -a -t complete -i test/fixtures/binaries/fwup.fw -d \"#{devpath}\"")

    opts = %{callback: self(), config: config, cache_pid: context.cache_pid}

    context
    |> Map.put(:binary_metadata, binary_metadata)
    |> Map.put(:upgrade_file, upgrade_file)
    |> Map.put(:opts, opts)
  end

  def update_installer_opts(binary_metadata, key, value) do
    custom_metadata =
      binary_metadata.custom_metadata
      |> update_in(["peridiod", "installer_opts", key], fn _ -> value end)

    %{binary_metadata | custom_metadata: custom_metadata}
  end

  defp spawn_installer(binary_metadata, opts) do
    opts = Map.put(opts, :callback, self())
    spawn(fn -> Installer.start_link(binary_metadata, opts) end)
  end
end

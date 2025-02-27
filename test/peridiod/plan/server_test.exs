defmodule Peridiod.Plan.ServerTest do
  use PeridiodTest.Case
  doctest Peridiod.Plan.Server

  alias Peridiod.{Binary, Plan}
  alias Peridiod.TestFixtures

  describe "bundle_install" do
    setup :load_release_metadata_from_manifest
    setup :start_cache
    setup :start_kv
    setup :step_opts
    setup :start_plan_server

    test "bundle single binary", %{
      step_opts: step_opts,
      plan_server_pid: pid,
      release_metadata: %{bundle: bundle_metadata}
    } do
      plan = Plan.resolve_install_bundle(bundle_metadata, step_opts)
      Plan.Server.execute_plan(pid, plan)
      assert_receive {Plan.Server, _pid, :complete}
    end

    test "bundle path install", %{
      step_opts: step_opts,
      plan_server_pid: pid,
      release_metadata: %{bundle: bundle_metadata}
    } do
      [binary_metadata] = bundle_metadata.binaries

      binary_metadata = %{
        binary_metadata
        | uri: Path.join(File.cwd!(), "test/fixtures/binaries/1M.bin")
      }

      step_opts = Keyword.put(step_opts, :filtered_binaries, [binary_metadata])
      plan = Plan.resolve_install_bundle(bundle_metadata, step_opts)
      Plan.Server.execute_plan(pid, plan)
      assert_receive {Plan.Server, _pid, :complete}
    end

    test "bundle path install bad signature", %{
      step_opts: step_opts,
      plan_server_pid: pid,
      release_metadata: %{bundle: bundle_metadata}
    } do
      [binary_metadata] = bundle_metadata.binaries

      binary_metadata = %{
        binary_metadata
        | uri: Path.join(File.cwd!(), "test/fixtures/binaries/1M-error.bin")
      }

      step_opts = Keyword.put(step_opts, :filtered_binaries, [binary_metadata])
      plan = Plan.resolve_install_bundle(bundle_metadata, step_opts)
      Plan.Server.execute_plan(pid, plan)
      assert_receive {Plan.Server, _pid, {:error, :invalid_hash}}
    end
  end

  describe "fwup" do
    setup :start_cache
    setup :start_kv
    setup :setup_fwup
    setup :step_opts
    setup :start_plan_server

    test "install task upgrade",
         %{
           step_opts: step_opts,
           plan_server_pid: pid,
           binary_metadata: binary_metadata
         } = context do
      plan = Plan.resolve_install_binaries([binary_metadata], step_opts)
      Plan.Server.execute_plan(pid, plan)
      assert_receive {Plan.Server, _pid, :complete}
      assert File.exists?(context.upgrade_file)
    end

    @tag capture_log: true
    test "install task error", %{
      step_opts: step_opts,
      plan_server_pid: pid,
      binary_metadata: binary_metadata
    } do
      binary_metadata = update_installer_opts(binary_metadata, "task", "does_not_exist")
      plan = Plan.resolve_install_binaries([binary_metadata], step_opts)
      Plan.Server.execute_plan(pid, plan)
      assert_receive {Plan.Server, _pid, {:error, error}}
      assert error =~ "does_not_exist"
    end

    @tag capture_log: true
    test "invalid signature", %{
      step_opts: step_opts,
      plan_server_pid: pid,
      binary_metadata: binary_metadata
    } do
      untrusted = TestFixtures.untrusted_release_binary() |> Binary.metadata_from_manifest()
      binary_metadata = Map.put(binary_metadata, :signatures, untrusted.signatures)
      plan = Plan.resolve_install_binaries([binary_metadata], step_opts)
      Plan.Server.execute_plan(pid, plan)
      assert_receive {Plan.Server, _pid, {:error, :invalid_signature}}
    end
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
end

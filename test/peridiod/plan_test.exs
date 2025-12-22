defmodule Peridiod.PlanTest do
  use PeridiodTest.Case
  doctest Peridiod.Plan

  alias Peridiod.TestFixtures
  alias Peridiod.{Plan, Binary}
  alias Peridiod.Plan.Step

  describe "bundle_install" do
    setup :load_release_metadata_from_manifest
    setup :step_opts

    test "bundle single binary", %{
      step_opts: step_opts,
      release_metadata: %{bundle: bundle_metadata}
    } do
      [binary_metadata] = bundle_metadata.binaries
      plan = Plan.resolve_install_bundle(bundle_metadata, step_opts)

      assert [
               {Step.Cache, %{action: :save_metadata, metadata: ^bundle_metadata}},
               {Step.SystemState, %{action: :progress, bundle_metadata: ^bundle_metadata}}
             ] = plan.on_init

      assert [[{Step.BinaryInstall, %{binary_metadata: ^binary_metadata}}]] = plan.run
      assert [{Step.SystemState, %{action: :progress_reset}}] = plan.on_error

      assert [
               {Step.Cache, %{metadata: ^bundle_metadata, action: :stamp_installed}},
               {Step.SystemState, %{action: :advance}}
             ] = plan.on_finish
    end

    test "release single binary", %{
      step_opts: step_opts,
      release_metadata: release_metadata
    } do
      [binary_metadata] = release_metadata.bundle.binaries
      bundle_metadata = release_metadata.bundle
      plan = Plan.resolve_install_bundle(release_metadata, step_opts)

      assert [
               {Step.Cache, %{action: :save_metadata, metadata: ^bundle_metadata}},
               {Step.Cache, %{action: :save_metadata, metadata: ^release_metadata}},
               {Step.SystemState,
                %{
                  action: :progress,
                  bundle_metadata: ^bundle_metadata,
                  via_metadata: ^release_metadata
                }}
             ] = plan.on_init

      assert [[{Step.BinaryInstall, %{binary_metadata: ^binary_metadata}}]] = plan.run
      assert [{Step.SystemState, %{action: :progress_reset}}] = plan.on_error

      assert [
               {Step.Cache, %{metadata: ^bundle_metadata, action: :stamp_installed}},
               {Step.Cache, %{metadata: ^release_metadata, action: :stamp_installed}},
               {Step.SystemState, %{action: :advance}}
             ] = plan.on_finish
    end

    test "bundle sequential binaries", %{
      step_opts: step_opts,
      release_metadata: %{bundle: bundle_metadata}
    } do
      sequential_binary_metadata =
        TestFixtures.binary_manifest_swupdate() |> Binary.metadata_from_manifest()

      [parallel_binary_metadata] = bundle_metadata.binaries

      bundle_metadata = %{
        bundle_metadata
        | binaries: [
            parallel_binary_metadata,
            sequential_binary_metadata,
            sequential_binary_metadata
          ]
      }

      plan = Plan.resolve_install_bundle(bundle_metadata, step_opts)

      assert [
               {Step.Cache, %{action: :save_metadata, metadata: ^bundle_metadata}},
               {Step.SystemState, %{action: :progress, bundle_metadata: ^bundle_metadata}}
             ] = plan.on_init

      assert [{Step.SystemState, %{action: :progress_reset}}] = plan.on_error

      assert [
               [
                 {Step.BinaryCache, %{binary_metadata: ^sequential_binary_metadata}}
               ],
               [
                 {Step.BinaryInstall, %{binary_metadata: ^parallel_binary_metadata}},
                 {Step.BinaryInstall,
                  %{binary_metadata: ^sequential_binary_metadata, source: :cache}}
               ],
               [
                 {Step.BinaryInstall,
                  %{binary_metadata: ^sequential_binary_metadata, source: :cache}}
               ]
             ] = plan.run

      assert [
               {Step.Cache, %{metadata: ^bundle_metadata, action: :stamp_installed}},
               {Step.SystemState, %{action: :advance}},
               {Step.SystemReboot, _}
             ] = plan.on_finish
    end

    test "filtered_binaries", %{
      step_opts: step_opts,
      release_metadata: %{bundle: bundle_metadata}
    } do
      step_opts = Keyword.put(step_opts, :filtered_binaries, [])
      plan = Plan.resolve_install_bundle(bundle_metadata, step_opts)
      assert plan.run == []
    end

    test "installed_binaries", %{
      step_opts: step_opts,
      release_metadata: %{bundle: bundle_metadata}
    } do
      [binary_metadata] = bundle_metadata.binaries
      step_opts = Keyword.put(step_opts, :installed_binaries, [binary_metadata])
      plan = Plan.resolve_install_bundle(bundle_metadata, step_opts)

      assert [{Step.BinaryState, %{metadata: ^binary_metadata, action: :put_kv_installed}} | _] =
               Enum.reverse(plan.on_init)
    end
  end

  describe "avocado bundle install" do
    setup :load_release_metadata_from_manifest
    setup :step_opts

    test "os + extensions bundle generates correct phases", %{
      step_opts: step_opts
    } do
      os_binary_manifest = TestFixtures.binary_manifest_avocado_os("v1.0.0")
      ext1_manifest = TestFixtures.binary_manifest_avocado_extension("app1")
      ext2_manifest = TestFixtures.binary_manifest_avocado_extension("app2")

      os_binary = Binary.metadata_from_manifest(os_binary_manifest)
      ext1 = Binary.metadata_from_manifest(ext1_manifest)
      ext2 = Binary.metadata_from_manifest(ext2_manifest)

      bundle_metadata = %Peridiod.Bundle{
        prn: "prn:1:test:bundle:avocado-test",
        binaries: [os_binary, ext1, ext2]
      }

      plan = Plan.resolve_install_bundle(bundle_metadata, step_opts)

      # IO.puts("\n=== Plan: OS + Extensions ===")
      # IO.inspect(plan.run, label: "Run steps", pretty: true, width: 120)
      # IO.inspect(plan.on_finish, label: "On finish", pretty: true, width: 120)

      # Should have extension installs, enable, and OS install
      assert is_list(plan.run)
      assert length(plan.run) >= 3

      # Verify ordering: extensions install -> enable -> OS install
      all_steps = List.flatten(plan.run)

      # Find positions of key steps
      ext1_pos =
        Enum.find_index(all_steps, fn
          {Step.BinaryInstall, %{binary_metadata: ^ext1}} -> true
          _ -> false
        end)

      ext2_pos =
        Enum.find_index(all_steps, fn
          {Step.BinaryInstall, %{binary_metadata: ^ext2}} -> true
          _ -> false
        end)

      enable_pos =
        Enum.find_index(all_steps, fn
          {Step.AvocadoExtensionEnable, _} -> true
          _ -> false
        end)

      os_pos =
        Enum.find_index(all_steps, fn
          {Step.BinaryInstall, %{binary_metadata: ^os_binary}} -> true
          _ -> false
        end)

      # Verify all steps exist
      assert ext1_pos != nil, "Extension 1 install step not found"
      assert ext2_pos != nil, "Extension 2 install step not found"
      assert enable_pos != nil, "Enable step not found"
      assert os_pos != nil, "OS install step not found"

      # Verify ordering: extensions before enable, enable before OS
      assert ext1_pos < enable_pos, "Extension 1 should install before enable"
      assert ext2_pos < enable_pos, "Extension 2 should install before enable"
      assert enable_pos < os_pos, "Enable should happen before OS install"

      # Should have reboot (OS requires it)
      assert Enum.any?(plan.on_finish, fn
               {Step.SystemReboot, _} -> true
               _ -> false
             end)
    end

    test "extensions only (no OS) generates refresh step", %{
      step_opts: step_opts
    } do
      ext1_manifest = TestFixtures.binary_manifest_avocado_extension("app1")
      ext1 = Binary.metadata_from_manifest(ext1_manifest)

      bundle_metadata = %Peridiod.Bundle{
        prn: "prn:1:test:bundle:avocado-ext-only",
        binaries: [ext1]
      }

      plan = Plan.resolve_install_bundle(bundle_metadata, step_opts)

      # IO.puts("\n=== Plan: Extensions Only (No OS) ===")
      # IO.inspect(plan.run, label: "Run steps", pretty: true, width: 120)
      # IO.inspect(plan.on_finish, label: "On finish", pretty: true, width: 120)

      all_steps = List.flatten(plan.run)

      # Find positions
      ext_pos =
        Enum.find_index(all_steps, fn
          {Step.BinaryInstall, %{binary_metadata: ^ext1}} -> true
          _ -> false
        end)

      enable_pos =
        Enum.find_index(all_steps, fn
          {Step.AvocadoExtensionEnable, opts} ->
            opts.os_version == nil and "app1" in opts.extension_names

          _ ->
            false
        end)

      refresh_pos =
        Enum.find_index(all_steps, fn
          {Step.AvocadoRefresh, _} -> true
          _ -> false
        end)

      # Verify all steps exist
      assert ext_pos != nil, "Extension install step not found"
      assert enable_pos != nil, "Enable step not found"
      assert refresh_pos != nil, "Refresh step not found"

      # Verify ordering: extension install -> enable -> refresh
      assert ext_pos < enable_pos, "Extension should install before enable"
      assert enable_pos < refresh_pos, "Enable should happen before refresh"

      # Should NOT have reboot (extension doesn't require it)
      refute Enum.any?(plan.on_finish, fn
               {Step.SystemReboot, _} -> true
               _ -> false
             end)
    end

    test "os only (no extensions) normal install", %{
      step_opts: step_opts
    } do
      os_binary_manifest = TestFixtures.binary_manifest_avocado_os("v2.0.0")
      os_binary = Binary.metadata_from_manifest(os_binary_manifest)

      bundle_metadata = %Peridiod.Bundle{
        prn: "prn:1:test:bundle:avocado-os-only",
        binaries: [os_binary]
      }

      plan = Plan.resolve_install_bundle(bundle_metadata, step_opts)

      # IO.puts("\n=== Plan: OS Only (No Extensions) ===")
      # IO.inspect(plan.run, label: "Run steps", pretty: true, width: 120)
      # IO.inspect(plan.on_finish, label: "On finish", pretty: true, width: 120)

      all_steps = List.flatten(plan.run)

      # Should NOT have extension enable
      refute Enum.any?(all_steps, fn
               {Step.AvocadoExtensionEnable, _} -> true
               _ -> false
             end)

      # Should NOT have refresh
      refute Enum.any?(all_steps, fn
               {Step.AvocadoRefresh, _} -> true
               _ -> false
             end)

      # Should have OS install
      assert Enum.any?(all_steps, fn
               {Step.BinaryInstall, %{binary_metadata: ^os_binary}} -> true
               _ -> false
             end)

      # Should have reboot
      assert Enum.any?(plan.on_finish, fn
               {Step.SystemReboot, _} -> true
               _ -> false
             end)
    end

    test "mixed avocado and non-avocado binaries", %{
      step_opts: step_opts
    } do
      os_binary_manifest = TestFixtures.binary_manifest_avocado_os("v1.5.0")
      ext_manifest = TestFixtures.binary_manifest_avocado_extension("myapp")
      regular_manifest = TestFixtures.binary_manifest_fwup()

      os_binary = Binary.metadata_from_manifest(os_binary_manifest)
      ext = Binary.metadata_from_manifest(ext_manifest)
      regular = Binary.metadata_from_manifest(regular_manifest)

      bundle_metadata = %Peridiod.Bundle{
        prn: "prn:1:test:bundle:mixed",
        binaries: [ext, regular, os_binary]
      }

      plan = Plan.resolve_install_bundle(bundle_metadata, step_opts)

      # IO.puts("\n=== Plan: Mixed Avocado and Non-Avocado ===")
      # IO.inspect(plan.run, label: "Run steps", pretty: true, width: 120)
      # IO.inspect(plan.on_finish, label: "On finish", pretty: true, width: 120)

      all_steps = List.flatten(plan.run)

      # Find positions of key steps
      ext_pos =
        Enum.find_index(all_steps, fn
          {Step.BinaryInstall, %{binary_metadata: ^ext}} -> true
          _ -> false
        end)

      enable_pos =
        Enum.find_index(all_steps, fn
          {Step.AvocadoExtensionEnable, _} -> true
          _ -> false
        end)

      regular_pos =
        Enum.find_index(all_steps, fn
          {Step.BinaryInstall, %{binary_metadata: ^regular}} -> true
          _ -> false
        end)

      os_pos =
        Enum.find_index(all_steps, fn
          {Step.BinaryInstall, %{binary_metadata: ^os_binary}} -> true
          _ -> false
        end)

      # Verify all steps exist
      assert ext_pos != nil, "Extension install step not found"
      assert enable_pos != nil, "Enable step not found"
      assert regular_pos != nil, "Regular binary install step not found"
      assert os_pos != nil, "OS install step not found"

      # Verify ordering: extension -> enable -> regular -> OS
      assert ext_pos < enable_pos, "Extension should install before enable"
      assert enable_pos < regular_pos, "Enable should happen before regular binary"
      assert regular_pos < os_pos, "Regular binary should install before OS"
    end

    test "empty extension list handling", %{
      step_opts: step_opts
    } do
      bundle_metadata = %Peridiod.Bundle{
        prn: "prn:1:test:bundle:empty",
        binaries: []
      }

      plan = Plan.resolve_install_bundle(bundle_metadata, step_opts)

      # IO.puts("\n=== Plan: Empty Bundle ===")
      # IO.inspect(plan.run, label: "Run steps", pretty: true, width: 120)
      # IO.inspect(plan.on_finish, label: "On finish", pretty: true, width: 120)

      # Should have empty run steps
      assert plan.run == []

      # Should NOT have avocado-specific steps
      all_steps = List.flatten(plan.run)

      refute Enum.any?(all_steps, fn
               {Step.AvocadoExtensionEnable, _} -> true
               _ -> false
             end)

      refute Enum.any?(all_steps, fn
               {Step.AvocadoRefresh, _} -> true
               _ -> false
             end)
    end

    test "already-installed extensions included in enable step", %{
      step_opts: step_opts
    } do
      # Create extensions
      ext1_manifest = TestFixtures.binary_manifest_avocado_extension("already-installed")
      ext2_manifest = TestFixtures.binary_manifest_avocado_extension("new-extension")
      os_manifest = TestFixtures.binary_manifest_avocado_os("v2.0.0")

      ext1 = Binary.metadata_from_manifest(ext1_manifest)
      ext2 = Binary.metadata_from_manifest(ext2_manifest)
      os_binary = Binary.metadata_from_manifest(os_manifest)

      # Simulate: ext1 is already installed, ext2 is new, OS is new
      step_opts =
        step_opts
        |> Keyword.put(:filtered_binaries, [ext2, os_binary])
        |> Keyword.put(:installed_binaries, [ext1])

      bundle_metadata = %Peridiod.Bundle{
        prn: "prn:1:test:bundle:mixed-installed",
        binaries: [ext1, ext2, os_binary]
      }

      plan = Plan.resolve_install_bundle(bundle_metadata, step_opts)

      # IO.puts("\n=== Plan: Already-Installed Extension Handling ===")
      # IO.inspect(plan.run, label: "Run steps", pretty: true, width: 120)

      all_steps = List.flatten(plan.run)

      # Find the enable step
      enable_step =
        Enum.find(all_steps, fn
          {Step.AvocadoExtensionEnable, _} -> true
          _ -> false
        end)

      assert enable_step != nil, "Enable step should exist"

      {Step.AvocadoExtensionEnable, enable_opts} = enable_step

      # Should include BOTH extensions (already-installed AND new)
      assert "already-installed" in enable_opts.extension_names,
             "Already-installed extension should be in enable list"

      assert "new-extension" in enable_opts.extension_names,
             "New extension should be in enable list"

      assert length(enable_opts.extension_names) == 2,
             "Should have exactly 2 extensions"

      # Should have OS version
      assert enable_opts.os_version == "v2.0.0"

      # Verify only NEW extension gets file install step
      ext_install_steps =
        Enum.filter(all_steps, fn
          {Step.BinaryInstall, %{binary_metadata: %{custom_metadata: cm}}} ->
            get_in(cm, ["peridiod", "installer"]) == "avocado-ext"

          _ ->
            false
        end)

      assert length(ext_install_steps) == 1, "Only new extension should have install step"

      {Step.BinaryInstall, %{binary_metadata: installed_ext}} = List.first(ext_install_steps)

      assert get_in(installed_ext.custom_metadata, [
               "peridiod",
               "avocado",
               "extension_name"
             ]) == "new-extension"
    end
  end
end

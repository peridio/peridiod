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
                 {Step.BinaryInstall, %{binary_metadata: ^sequential_binary_metadata, source: :cache}}
               ],
               [{Step.BinaryInstall, %{binary_metadata: ^sequential_binary_metadata, source: :cache}}]
             ] = plan.run

      assert [
               {Step.Cache, %{metadata: ^bundle_metadata, action: :stamp_installed}},
               {Step.SystemState, %{action: :advance}}
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
end

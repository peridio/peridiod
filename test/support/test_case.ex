defmodule PeridiodTest.Case do
  use ExUnit.CaseTemplate

  alias PeridiodPersistence.KV
  alias Peridiod.{Cloud, Cache, Release, Bundle, Plan}
  alias PeridiodTest.StaticRouter
  alias Peridiod.TestFixtures

  using do
    quote do
      import unquote(__MODULE__)
      PeridiodTest.Case
    end
  end

  setup_all do
    Plug.Cowboy.http(StaticRouter, [], port: 4001)
    on_exit(fn -> Plug.Cowboy.shutdown(StaticRouter) end)
    :ok
  end

  setup context do
    install_dir = "test/workspace/install/#{context.test}"

    opts = [
      release_manifest: TestFixtures.release_manifest(install_dir),
      trusted_signing_key: TestFixtures.trusted_signing_key(),
      untrusted_signing_key: TestFixtures.untrusted_signing_key()
    ]

    {:ok, opts}
  end

  def load_release_metadata_from_manifest(%{release_manifest: release_manifest} = context) do
    {:ok, release_metadata} = Release.metadata_from_manifest(release_manifest)
    Map.put(context, :release_metadata, release_metadata)
  end

  def load_bundle_metadata_from_manifest(%{release_manifest: release_manifest} = context) do
    {:ok, bundle_metadata} = Bundle.metadata_from_manifest(release_manifest)
    Map.put(context, :bundle_metadata, bundle_metadata)
  end

  def start_cache(context) do
    application_config = Application.get_all_env(:peridiod)
    config = struct(Peridiod.Config, application_config) |> Peridiod.Config.new()
    cache_dir = "test/workspace/cache/#{context.test}"
    config = Map.put(config, :cache_dir, cache_dir)
    {:ok, cache_pid} = Cache.start_link(config, [])

    context
    |> Map.put(:cache_pid, cache_pid)
    |> Map.put(:cache_dir, cache_dir)
  end

  def start_kv(context) do
    persistence_config = Application.get_all_env(:peridiod_persistence)
    {:ok, kv_pid} = KV.start_link(persistence_config, [])

    Map.put(context, :kv_pid, kv_pid)
  end

  def start_bundle_server(%{cache_pid: cache_pid} = context) do
    application_config = Application.get_all_env(:peridiod)
    config = struct(Peridiod.Config, application_config) |> Peridiod.Config.new()
    config = Map.put(config, :cache_pid, cache_pid)

    config =
      if kv_pid = context[:kv_pid] do
        Map.put(config, :kv_pid, kv_pid)
      else
        config
      end

    config =
      if plan_server_pid = context[:plan_server_pid] do
        Map.put(config, :plan_server_pid, plan_server_pid)
      else
        config
      end

    {:ok, _pid} = Cloud.start_link(config, [])
    {:ok, pid} = Bundle.Server.start_link(config, [])
    Map.put(context, :bundle_server_pid, pid)
  end

  def start_plan_server(context) do
    {:ok, pid} = Plan.Server.start_link(nil, [])
    Map.put(context, :plan_server_pid, pid)
  end

  def step_opts(ctx) do
    step_opts = Map.take(ctx, [:cache_pid, :kv_pid])
    Map.put(ctx, :step_opts, Enum.into(step_opts, []))
  end
end

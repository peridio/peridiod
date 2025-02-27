defmodule Peridiod.Plan.Step.SystemState do
  use Peridiod.Plan.Step

  alias Peridiod.{Cloud, State}
  alias PeridiodPersistence.KV

  def id(_step_opts) do
    Module.concat(__MODULE__, UUID.uuid4())
  end

  def init(%{cache_pid: cache_pid, kv_pid: kv_pid, action: action} = opts) do
    args = opts[:args]
    bundle_metadata = opts[:bundle_metadata]
    via_metadata = opts[:via_metadata]

    {:ok,
     %{
       cache_pid: cache_pid,
       kv_pid: kv_pid,
       action: action,
       args: args,
       bundle_metadata: bundle_metadata,
       via_metadata: via_metadata
     }}
  end

  def execute(%{cache_pid: cache_pid, kv_pid: kv_pid, action: :advance} = state) do
    State.advance(kv_pid)
    kv = KV.get_all(kv_pid)

    Cloud.update_client_headers(
      via_prn: kv["peridio_via_current"],
      bundle_prn: kv["peridio_bun_current"],
      release_version: kv["peridio_vsn_current"]
    )

    State.cache_clean(cache_pid, kv)
    {:stop, :normal, state}
  end

  def execute(%{kv_pid: kv_pid, action: :progress, bundle_metadata: bundle_metadata} = state) do
    State.progress(kv_pid, bundle_metadata, state[:via_metadata])
    {:stop, :normal, state}
  end

  def execute(%{kv_pid: kv_pid, action: :progress_reset} = state) do
    State.progress_reset(kv_pid)
    {:stop, :normal, state}
  end
end

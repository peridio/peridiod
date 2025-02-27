defmodule Peridiod.Plan.Step.Cache do
  use Peridiod.Plan.Step

  require Logger

  def id(_step_opts) do
    Module.concat(__MODULE__, UUID.uuid4())
  end

  def init(%{metadata: metadata, action: action} = opts) do
    {:ok, %{metadata: metadata, action: action, cache_pid: opts[:cache_pid]}}
  end

  def execute(%{metadata: metadata, action: :stamp_installed, cache_pid: cache_pid} = state) do
    metadata.__struct__.stamp_installed(cache_pid, metadata)
    {:stop, :normal, state}
  end

  def execute(%{metadata: metadata, action: :stamp_cached, cache_pid: cache_pid} = state) do
    metadata.__struct__.stamp_cached(cache_pid, metadata)
    {:stop, :normal, state}
  end

  def execute(%{metadata: metadata, action: :save_metadata, cache_pid: cache_pid} = state) do
    metadata.__struct__.metadata_to_cache(cache_pid, metadata)
    {:stop, :normal, state}
  end
end

defmodule Peridiod.Plan.Step.BinaryState do
  use Peridiod.Plan.Step

  alias Peridiod.Binary

  def id(_step_opts) do
    Module.concat(__MODULE__, UUID.uuid4())
  end

  def init(%{metadata: metadata, action: action} = opts) do
    {:ok, %{metadata: metadata, action: action, args: opts[:args], kv_pid: opts[:kv_pid]}}
  end

  def execute(%{metadata: metadata, action: :put_kv_installed, kv_pid: kv_pid} = state) do
    store = state.args[:store] || :progress
    Binary.put_kv_installed(kv_pid, metadata, store)
    {:stop, :normal, state}
  end

  def execute(%{metadata: metadata, action: :pop_kv_installed, kv_pid: kv_pid} = state) do
    store = state.args[:store] || :progress
    Binary.pop_kv_installed(kv_pid, metadata, store)
    {:stop, :normal, state}
  end
end

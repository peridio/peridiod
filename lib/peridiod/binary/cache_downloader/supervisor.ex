defmodule Peridiod.Binary.CacheDownloader.Supervisor do
  use DynamicSupervisor

  alias Peridiod.Binary.CacheDownloader
  alias Peridiod.Binary

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def start_child(%Binary{} = binary_metadata, opts \\ %{}) do
    child_spec = CacheDownloader.child_spec(binary_metadata, opts)
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end

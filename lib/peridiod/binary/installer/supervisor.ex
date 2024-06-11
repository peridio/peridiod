defmodule Peridiod.Binary.Installer.Supervisor do
  use DynamicSupervisor

  alias Peridiod.Binary
  alias Peridiod.Binary.Installer

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_child(%Binary{} = binary_metadata, opts \\ %{}) do
    child_spec = Installer.child_spec(binary_metadata, opts)
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end

defmodule Peridiod.Binary.Installer.Supervisor do
  use DynamicSupervisor

  alias Peridiod.Binary
  alias Peridiod.Binary.Installer

  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def start_installer(%Binary{} = binary_metadata, mod, opts \\ %{}) do
    child_spec = Installer.child_spec(binary_metadata, mod, opts)
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end

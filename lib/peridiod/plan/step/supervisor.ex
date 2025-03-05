defmodule Peridiod.Plan.Step.Supervisor do
  use DynamicSupervisor

  require Logger

  alias Peridiod.Plan.Step

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  def start_child({step_mod, step_opts}) do
    Logger.info("[Step Supervisor] Starting Step #{step_mod}")
    child_spec = Step.child_spec({step_mod, step_opts})
    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end

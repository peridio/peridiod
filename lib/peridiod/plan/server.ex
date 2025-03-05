defmodule Peridiod.Plan.Server do
  use GenServer

  require Logger

  alias Peridiod.Plan
  alias Peridiod.Plan.Step

  @error_timeout 10_000

  def start_link(opts, genserver_opts \\ [name: __MODULE__]) do
    GenServer.start_link(__MODULE__, opts, genserver_opts)
  end

  def execute_plan(pid_or_name \\ __MODULE__, %Plan{} = plan) do
    GenServer.call(pid_or_name, {:run_plan, plan})
  end

  def init(_opts) do
    {:ok,
     %{
       plan: nil,
       phase: nil,
       sequence: [],
       processing: [],
       callback: nil,
       status: :ok,
       error_timer: nil,
       error_timeout: @error_timeout
     }}
  end

  def handle_call({:run_plan, plan}, {from, _ref}, %{plan: nil} = state) do
    Logger.info("[Plan Server] Plan execution starting")
    {:reply, :ok, phase_change(:init, %{state | plan: plan, callback: from})}
  end

  def handle_call({:run_plan, _plan}, _from, state) do
    Logger.warning("[Plan Server] Plan is already executing")
    {:reply, {:error, "Server is busy with another plan"}, state}
  end

  # Init Complete
  def handle_info(
        {Step, pid, :complete},
        %{phase: :init, processing: [pid], sequence: [], status: :ok} = state
      ) do
    Logger.info("[Plan Server] on_init complete")
    {:noreply, phase_change(:run, %{state | processing: []})}
  end

  # Run Complete
  def handle_info(
        {Step, pid, :complete},
        %{phase: :run, processing: [pid], sequence: [], status: :ok} = state
      ) do
    Logger.info("[Plan Server] run complete")
    {:noreply, phase_change(:finish, %{state | processing: []})}
  end

  # Finish Complete
  def handle_info(
        {Step, pid, :complete},
        %{phase: :finish, processing: [pid], sequence: [], status: :ok} = state
      ) do
    Logger.info("[Plan Server] on_finish complete")
    {:noreply, plan_finished(%{state | processing: []})}
  end

  # Error Complete
  def handle_info(
        {Step, pid, :complete},
        %{phase: :error, processing: [pid], sequence: []} = state
      ) do
    Logger.info("[Plan Server] on_error complete")
    {:noreply, plan_finished(%{state | processing: []})}
  end

  # Execute next steps
  def handle_info({Step, pid, :complete}, %{processing: [pid], sequence: [step | tail], status: :ok} = state) do
    Logger.info("[Step Server] Phase complete, executing next phase")
    state = pop_processing(pid, state)
    processing = state.processing ++ execute(step)
    {:noreply, %{state | processing: processing, sequence: tail}}
  end

  def handle_info({Step, pid, :complete}, %{processing: [_ | _], sequence: [_ | _], status: :ok} = state) do
    Logger.info("[Step Server] Step finished")
    {:noreply, pop_processing(pid, state)}
  end

  def handle_info({Step, pid, :complete}, %{sequence: [], status: :ok} = state) do
    Logger.info("[Step Server] Final Step finished")
    {:noreply, pop_processing(pid, state)}
  end

  # Step on_error
  def handle_info(
        {Step, pid, {:error, error}},
        %{phase: :error, sequence: [step | tail]} = state
      ) do
    try_send(state.callback, {:error, error})
    state = pop_processing(pid, state)
    processing = state.processing ++ execute(step)
    {:noreply, %{state | processing: processing, sequence: tail}}
  end

  def handle_info({Step, pid, _resp}, %{processing: [pid], status: :error} = state) do
    Logger.error("[Plan Server] in-flight step tasks finished")
    state = phase_change(:error, state)
    Process.cancel_timer(state.error_timer)
    {:noreply, %{state | error_timer: nil}}
  end

  def handle_info({Step, pid, _resp}, %{status: :error} = state) do
    state = pop_processing(pid, state)
    {:noreply, state}
  end

  def handle_info({Step, pid, {:error, error}}, state) do
    Logger.error("[Plan Server] Error processing step #{inspect(error)}")
    state = pop_processing(pid, state)
    try_send(state.callback, {:error, error})
    {:noreply, transition_to_error(state)}
  end

  def handle_info(:force_error_phase, state) do
    Logger.warning("[Plan Server] Forcefully exiting tasks and transitioning to error phase")
    Enum.each(state.processing, &Process.exit(&1, :normal))
    state = phase_change(:error, state)
    {:noreply, %{state | processing: []}}
  end

  def handle_info({:DOWN, _ref, :process, _pid, :normal}, state) do
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, pid, error}, state) do
    Logger.error("[Plan Server] Step exited abnormally")
    state = pop_processing(pid, state)
    try_send(state.callback, {:error, error})
    {:noreply, transition_to_error(state)}
  end

  def handle_info(message, state) do
    Logger.warning(
      "[Plan Server] Unhandled message #{inspect(message, structs: false, limit: :infinity, printable_limit: :infinity)} #{inspect(state, structs: false, limit: :infinity, printable_limit: :infinity)}"
    )

    {:noreply, state}
  end

  defp transition_to_error(%{processing: []} = state) do
    phase_change(:error, state)
  end
  defp transition_to_error(state) do
    Logger.warning(
      "[Plan Server] Waiting #{trunc(state.error_timeout / 1000)}s for in-flight steps to clear before forcefully transitioning to on_error"
    )
    error_timer = Process.send_after(self(), :force_error_phase, state.error_timeout)
    %{state | error_timer: error_timer, status: :error}
  end

  defp phase_change(:init, %{plan: %{on_init: []}} = state),
    do: phase_change(:run, state)

  defp phase_change(:init, %{plan: %{on_init: [next | tail]}} = state) do
    Logger.info("[Plan Server] on_init starting")
    %{state | phase: :init, sequence: tail, processing: execute(next)}
  end

  defp phase_change(:run, %{plan: %{run: []}} = state),
    do: phase_change(:finish, state)

  defp phase_change(:run, %{plan: %{run: [next | tail]}} = state) do
    Logger.info("[Plan Server] run starting")
    %{state | phase: :run, sequence: tail, processing: execute(next)}
  end

  defp phase_change(:finish, %{plan: %{on_finish: []}} = state),
    do: plan_finished(state)

  defp phase_change(:finish, %{plan: %{on_finish: [next | tail]}} = state) do
    Logger.info("[Plan Server] on_finish starting")
    %{state | phase: :finish, sequence: tail, processing: execute(next)}
  end

  defp phase_change(:error, %{plan: %{on_error: []}} = state),
    do: plan_finished(state)

  defp phase_change(:error, %{plan: %{on_error: [next | tail]}} = state) do
    Logger.info("[Plan Server] on_error starting")
    %{state | phase: :error, sequence: tail, processing: execute(next)}
  end

  defp plan_finished(%{phase: :error} = state) do
    Logger.error("[Plan Server] Plan finished with errors")
    try_send(state.callback, :error)
    reset_state(state)
  end

  defp plan_finished(state) do
    Logger.info("[Plan Server] Plan finished")
    try_send(state.callback, :complete)
    reset_state(state)
  end

  defp reset_state(state) do
    %{
      state
      | plan: nil,
        phase: nil,
        sequence: [],
        processing: [],
        callback: nil,
        error_timer: nil,
        status: :ok
    }
  end

  defp execute([_ | _] = parallel_steps) do
    Enum.flat_map(parallel_steps, &execute/1)
  end

  defp execute(step) do
    {:ok, pid} = Step.Supervisor.start_child(step)
    Process.monitor(pid)
    Step.execute(pid)
    [pid]
  end

  defp pop_processing(pid, state) do
    {_pid, processing} = Enum.split_with(state.processing, &(&1 == pid))
    %{state | processing: processing}
  end

  defp try_send(nil, _msg), do: :ok

  defp try_send(pid, msg) do
    if self() != pid and Process.alive?(pid) do
      send(pid, {__MODULE__, self(), msg})
    end
  end
end

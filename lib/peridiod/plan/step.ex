defmodule Peridiod.Plan.Step do
  defmacro __using__(_opts) do
    quote do
      @behaviour Peridiod.Plan.Step.Behaviour

      def init(opts) do
        {:error, :not_implemented, opts}
      end

      def execute(state) do
        {:error, :not_implemented, state}
      end

      def handle_info(_message, state) do
        {:noreply, state}
      end

      defoverridable init: 1,
                     execute: 1,
                     handle_info: 2
    end
  end

  use GenServer

  require Logger

  def child_spec({step_mod, step_opts}) do
    step_opts = Map.put_new(step_opts, :callback, self())

    %{
      id: step_mod.id(step_opts),
      start: {__MODULE__, :start_link, [{step_mod, step_opts}]},
      restart: :temporary,
      shutdown: 5000,
      type: :worker
    }
  end

  def execute(pid) do
    GenServer.cast(pid, :execute)
  end

  def start_link({step_mod, step_opts}) do
    GenServer.start_link(__MODULE__, {step_mod, step_opts})
  end

  def init({step_mod, step_opts}) do
    Process.flag(:trap_exit, true)
    callback = step_opts[:callback]

    case step_mod.init(step_opts) do
      {:ok, step_state} ->
        {:ok,
         %{
           callback: callback,
           step_mod: step_mod,
           step_state: step_state
         }}

      {:error, error, _step_state} ->
        try_send(callback, {:error, error})
        {:stop, :normal, nil}

      {:stop, reason, _step_state} ->
        {:stop, reason, nil}
    end
  end

  def handle_cast(:execute, state) do
    state.step_mod.execute(state.step_state)
    |> step_response(state)
  end

  def handle_info({:EXIT, _pid, :normal}, state) do
    Logger.error("[Step] child process exited normally")
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, _pid, reason}, state) do
    Logger.error("[Step] child process exited abnormally")
    {:stop, {:error, reason}, state}
  end

  def handle_info(msg, state) do
    state.step_mod.handle_info(msg, state.step_state)
    |> step_response(state)
  end

  defp step_response(response, state) do
    case response do
      {:noreply, step_state} ->
        {:noreply, %{state | step_state: step_state}}

      {:error, error, step_state} ->
        try_send(state.callback, {:error, error})
        {:stop, :normal, %{state | step_state: step_state}}

      {:stop, :normal, step_state} ->
        try_send(state.callback, :complete)
        {:stop, :normal, %{state | step_state: step_state}}
    end
  end

  defp try_send(nil, _msg), do: :ok

  defp try_send(pid, msg) do
    if self() != pid and Process.alive?(pid) do
      send(pid, {__MODULE__, self(), msg})
    end
  end
end

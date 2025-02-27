defmodule Peridiod.Plan.Step.Behaviour do
  @type step_state :: any
  @type step_opts :: map

  @callback id(step_opts) :: atom
  @callback init(step_opts) ::
              {:ok, step_state}
              | {:error, reason :: any(), step_state()}
              | {:stop, reason :: any(), step_state()}
  @callback execute(step_state) ::
              {:ok, step_state}
              | {:noreply, step_state}
              | {:error, reason :: any(), step_state()}
              | {:stop, reason :: any(), step_state()}
  @callback handle_info(any, step_state) ::
              {:noreply, step_state}
              | {:error, reason :: any(), step_state()}
              | {:stop, reason :: any(), step_state()}
end

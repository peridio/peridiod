defmodule Peridiod.Binary.Installer.Behaviour do
  alias Peridiod.Binary

  @type installer_state :: any()
  @type installer_opts :: map()

  @callback execution_model() :: :parallel | :sequential
  @callback interfaces() :: [:path | :stream]
  @callback path_install(Binary.t(), String.t(), installer_opts) ::
              {:stop, reason :: any(), installer_state()}
              | {:noreply, installer_state()}
              | {:error, reason :: any(), installer_state()}
  @callback stream_init(Binary.t(), installer_opts) ::
              {:ok, installer_state()} | {:error, reason :: any(), installer_state()}
  @callback stream_update(Binary.t(), data :: binary(), installer_state()) ::
              {:ok, installer_state()} | {:error, reason :: any(), installer_state()}
  @callback stream_info(msg :: any, installer_state()) ::
              {:ok, installer_state()} | {:error, reason :: any(), installer_state()}
  @callback stream_error(Binary.t(), reason :: any(), installer_state()) ::
              {:ok, installer_state()} | {:error, reason :: any(), installer_state()}
  @callback stream_finish(Binary.t(), :valid_signature | :invalid_signature, installer_state()) ::
              {:stop, reason :: any(), installer_state()}
              | {:noreply, installer_state()}
              | {:error, reason :: any(), installer_state()}
end

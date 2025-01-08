defmodule Peridiod.Binary.Installer.Behaviour do
  defmacro __using__(_opts) do
    quote do
      @behaviour Peridiod.Binary.Installer.Behaviour

      def install_downloader(%Peridiod.Binary{}, _installer_opts) do
        Peridiod.Binary.CacheDownloader
      end

      def install_init(%Peridiod.Binary{}, _source, _config) do
        {:ok, %{}}
      end

      def install_update(%Peridiod.Binary{}, {:error, reason}, state) do
        {:error, reason, state}
      end

      def install_update(%Peridiod.Binary{}, data, state) do
        {:ok, state}
      end

      def install_finish(%Peridiod.Binary{}, :invalid_signature, state) do
        {:error, :invalid_signature, state}
      end

      def install_info(_msg, installer_state) do
        {:ok, installer_state}
      end

      def install_error(%Peridiod.Binary{}, error, installer_state) do
        {:error, error, installer_state}
      end

      defoverridable install_downloader: 2,
                     install_init: 3,
                     install_update: 3,
                     install_finish: 3,
                     install_info: 2,
                     install_error: 3
    end
  end

  alias Peridiod.Binary
  alias Peridiod.Binary.{CacheDownloader, StreamDownloader}

  @type installer_state :: any()
  @type installer_opts :: map()

  @callback install_downloader(Binary.t(), installer_opts) :: StreamDownloader | CacheDownloader
  @callback install_init(Binary.t(), :cache | :download, installer_opts, installer_state()) ::
              {:ok, installer_state()} | {:error, reason :: any(), installer_state()}
  @callback install_update(Binary.t(), data :: binary(), installer_state()) ::
              {:ok, installer_state()} | {:error, reason :: any(), installer_state()}
  @callback install_info(msg :: any, installer_state()) ::
              {:ok, installer_state()} | {:error, reason :: any(), installer_state()}
  @callback install_error(Binary.t(), reason :: any(), installer_state()) ::
              {:ok, installer_state()} | {:error, reason :: any(), installer_state()}
  @callback install_finish(Binary.t(), :valid_signature | :invalid_signature, installer_state()) ::
              {:stop, reason :: any(), installer_state()}
              | {:noreply, installer_state()}
              | {:error, reason :: any(), installer_state()}
end
